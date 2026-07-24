# AI Integration Design Assessment

## Executive Summary

This Rails app ("hostedgpt") is a multi-provider ChatGPT-style front end. Its AI integration is built on **three separate provider SDK gems** — `ruby-openai` (~> 7.0.1), `ruby-anthropic` (~> 0.4.0), and `gemini-ai` (~> 4.2.0) — wrapped behind a hand-rolled `AIBackend` abstraction with one subclass per provider. A fourth gem, `tiktoken_ruby`, is declared in the `Gemfile` but is **not referenced anywhere in `app/` or `lib/`** (it is a dead dependency).

The app exercises a meaningful but bounded slice of AI capability: chat completions, **streaming** (SSE via Faraday), **tool/function calling** (normalized to the OpenAI tool-call shape), **structured JSON output** (used only for auto-titling conversations), and **multimodal input** (images and PDF text for vision models). It also does **image generation**, but that path bypasses the `AIBackend` abstraction entirely and calls `OpenAI::Client` directly from `Toolbox::Image`. It does **not** use embeddings, audio transcription, moderation, or token-counting despite `tiktoken_ruby` being present.

**Recommendation: none of the three options is clearly dominant, but the strongest case is for *RubyLLM*.** The current per-provider SDK approach already carries almost all the cost of a custom abstraction (a hand-built provider-normalization layer in `AIBackend` + `AIBackend::Tools` + per-provider `preceding_conversation_messages`/`format_parallel_tool_calls`) *without* the benefit of a single unified interface — call sites still branch on backend class (e.g. `AutotitleConversationJob#generate_title_for` has separate OpenAI/Anthropic/Gemini branches). RubyLLM would collapse the three SDKs and the `AIBackend` layer into one maintained interface that covers exactly the features this app uses (chat, streaming, tools, JSON schema, vision, image generation), with built-in retries, a unified error hierarchy, and a model registry. The "custom code" option is viable because the app's feature surface is small, but it would mean re-implementing streaming SSE parsing, tool-call accumulation, and the provider-format normalization that the team has already written — i.e. re-doing work that already exists, only without Faraday middleware and retry logic that the SDKs/RubyLLM provide for free. Keeping the status quo is defensible but offers the least long-term leverage.

---

## Current Implementation Overview

### Gems in use (`Gemfile`)

- `ruby-openai`, `~> 7.0.1` — OpenAI / any OpenAI-compatible endpoint (Groq is configured via `APIService::URL_GROQ`).
- `ruby-anthropic`, `~> 0.4.0` — Anthropic Claude.
- `gemini-ai`, `~> 4.2.0` — Google Gemini.
- `tiktoken_ruby`, `~> 0.0.9` — **declared but unused in application code** (no matches under `app/` or `lib/`). Likely a leftover.

All three SDKs sit on top of **Faraday**, which the app relies on directly for its error classes (`Faraday::UnauthorizedError`, `Faraday::ParsingError`, `Faraday::ConnectionFailed`, `Faraday::TooManyRequestsError`, `Faraday::BadRequestError`).

### Core abstraction: `AIBackend` (`app/services/ai_backend.rb`)

`AIBackend` is an abstract base class including `Utilities` and `Tools` concerns. It exposes two main entry points:

- `#get_oneoff_message(instructions, messages, params)` — non-streaming one-shot (used by `AutotitleConversationJob`).
- `#stream_next_conversation_message(&chunk_handler)` — streaming chat with tool-call support (used by `GetNextAIMessageJob`).

Subclasses (`AIBackend::OpenAI`, `AIBackend::Anthropic`, `AIBackend::Gemini`) implement:
- `client_method_name` (`:chat` / `:messages` / `:stream_generate_content`),
- `set_client_config` (provider-specific request shape),
- `stream_handler` (provider-specific chunk parsing, *except* Gemini which inlines its streaming loop),
- `preceding_conversation_messages` (provider-specific message formatting — notably different for tool messages and images),
- `format_parallel_tool_calls` (per-provider, in `ai_backend/open_ai/tools.rb` and `ai_backend/anthropic/tools.rb`).

The base class delegates to `@client.send(client_method_name, **@client_config)`, so each subclass is coupled to its SDK's method names and parameter conventions.

### Provider selection & credentials (`app/models/api_service.rb`, `app/models/language_model.rb`)

- `APIService` has a `driver` enum (`openai | anthropic | gemini`) and dispatches `#ai_backend` to the matching `AIBackend::*` class.
- The token is `encrypts :token` (ActiveRecord encryption) with `effective_token` falling back to app-level default keys (`Setting.default_openai_key`, etc.) gated by `Feature.default_llm_keys?`.
- `requires_token?` is URL-based — only the three known provider URLs require a token, so self-hosted/OpenAI-compatible endpoints can run tokenless.
- `LanguageModel` delegates `ai_backend` to its `api_service` and carries capability flags such as `supports_tools?` and `supports_system_message?`/`supports_images?` (the latter via assistant).

### Streaming (`AIBackend#stream_next_conversation_message`, `GetNextAIMessageJob`)

The job streams chunks into `@message.content_text` and broadcasts Turbo updates on a 0.1s throttle (`GetNextAIMessageJob.broadcast_updated_message`). Cancellation is cooperative via `ResponseCancelled`. Each provider's `stream_handler` accumulates `@stream_response_text` and `@stream_response_tool_calls`; OpenAI uses a custom `deep_streaming_merge` to assemble fragmented tool-call deltas, Anthropic has a dedicated `handle_tool_use_streaming` state machine over `content_block_start/delta/stop` events, and Gemini iterates an enumerator. Token usage is captured per-chunk onto `@message.input_token_count`/`output_token_count`.

### Tool / function calling (`app/services/toolbox.rb`, `app/services/ai_backend/tools.rb`)

- `Toolbox < SDK` is the base for all tools (`Toolbox::OpenMeteo`, `Toolbox::Image`, `Toolbox::Memory`, `Toolbox::GoogleSearch`, `Toolbox::Gmail`, `Toolbox::GoogleTasks`, `Toolbox::HelloWorld`).
- Tool schemas are **generated by reflection**: `Toolbox.function_tools` inspects instance method parameters and infers JSON-schema types from a naming convention (`_s` → string, `_i` → integer, `_f` → number, `is_` → boolean, `_enum` → enum). This is a bespoke convention not tied to any SDK.
- The **canonical tool-call shape is OpenAI's** (`{id, type:"function", function:{name, arguments}}`). Anthropic tool calls are converted to/from this shape in `AIBackend::Anthropic::Tools#format_parallel_tool_calls` and `preceding_conversation_messages`; Gemini has no tool support wired into the streaming path.
- Tool dispatch is in `AIBackend::Tools.get_tool_messages_by_calling` — it routes `name` to the matching `Toolbox::*` class, slices hallucinated args, and returns `role: "tool"` messages. Errors inside a tool are caught and turned into an LLM-readable string rather than raised.
- Parallel tool calls: OpenAI has special handling in `AIBackend::OpenAI::Tools#format_parallel_tool_calls` to split a malformed single-call response containing concatenated `call_…` ids into separate calls.

### Structured output / JSON schema

Only **JSON mode** is used, and only for auto-titling (`AutotitleConversationJob#generate_title_for`): OpenAI gets `response_format: { type: "json_object" }`, Gemini gets `generation_config: { response_mime_type: "application/json" }`, Anthropic gets a prompt-instruction workaround (and a different `system_message`). There is **no JSON-schema / structured-output** usage anywhere in the app. The branching on backend class here is a clear symptom of the lack of a unified interface.

### Multimodal

Vision input (images + PDF text extraction) is supported in `preceding_conversation_messages` for all three providers, each with its own content-part format (OpenAI `image_url`, Anthropic base64 `image` source, Gemini `inline_data`). PDFs are not sent natively; text is extracted via `pdf-reader` and inlined. There is **no audio or video** input. Image *output* is generated through `Toolbox::Image#generate_with_openai_client`, which **instantiates `OpenAI::Client` directly** — bypassing `AIBackend` entirely and requiring the user to have an OpenAI API service configured regardless of their chosen chat provider.

### Embeddings, audio, moderation

**Not used.** No references to `embed`, `transcribe`, or `moderate` exist in the codebase.

### Error handling and retries (`GetNextAIMessageJob#perform`)

The job is the central error boundary. It rescues, in order:
- `ResponseCancelled` → wrap up.
- `OpenAI::ConfigurationError` → per-name user-facing message (OpenAI vs Groq vs generic).
- `Anthropic::ConfigurationError`, `Gemini::Errors::ConfigurationError` (monkey-patched into `Gemini::Errors` in two separate files) → provider-specific messages.
- `Faraday::ParsingError` (also raised deliberately on blank responses) → "blank response" message.
- `Faraday::ConnectionFailed` → connection error message.
- `Faraday::TooManyRequestsError` → billing/quota message with a per-provider billing URL.
- `WaitForPrevious` → `retry_on` with exponential backoff (2^n seconds, 3 attempts).
- Catch-all → manual re-enqueue up to 3 attempts with linear `(attempt+1).seconds` delay, then a generic error message; secrets (`sk-…`) are scrubbed from logs.

There is **no SDK-level retry**: `ruby-openai`/`ruby-anthropic`/`gemini-ai` retry config is not set, so all retry/backoff is hand-rolled in the job. Rate-limit (429) is treated as a billing error rather than retried.

### Testability (`test/support/test_client/`)

Because Rails system tests run the server in a separate process that can't be mocked, each `AIBackend::*` subclass swaps its client class via `self.client` returning `TestClient::*` when `Rails.env.test?`. `TestClient::OpenAI/Anthropic/Gemini` are hand-built fakes with stubbable class-level attributes (`text`, `function`, `num_tool_calls`, `arguments`, `id`). Tests use `Minitest::stub` and `minitest-stub_any_instance`. WebMock is available but the TestClient pattern is what's actually used. The fakes are tightly coupled to the SDK method names (`chat`, `messages`, `stream_generate_content`), so they would need to be rewritten under any non-SDK approach.

### Observability

`Rails.logger.info` calls are sprinkled through `AIBackend::*` and the job (including `print content_chunk` in development). Token counts are persisted on `Message`. There is no structured instrumentation, no distributed tracing, and no centralized request logging — each backend logs its own "Connecting to … with access token of length N" line.

### Coupling between business logic and SDK APIs

Significant and visible:
- The job rescues SDK-specific exception classes (`OpenAI::ConfigurationError`, `Anthropic::ConfigurationError`) by name.
- `Gemini::Errors::ConfigurationError` is monkey-patched in **two** places (`ai_backend/gemini.rb:3` and `get_next_ai_message_job.rb:4`) because the gem doesn't define it.
- `Toolbox::Image` depends on `OpenAI::Client` directly.
- `AutotitleConversationJob` branches on `AIBackend` subclass identity to pick params.
- The OpenAI tool-call shape is the de-facto internal canonical format, so Anthropic support is forever doing conversion.

---

## Comparison Table

| Category | Current AI SDKs (ruby-openai / ruby-anthropic / gemini-ai) | RubyLLM | Custom Code (drop SDKs, hand-roll HTTP) |
|---|---|---|---|
| Provider support | 3 SDKs → OpenAI-compatible (OpenAI, Groq), Anthropic, Gemini. Adding a 4th provider means a new gem + new `AIBackend` subclass + new `TestClient`. | One gem, 12+ providers incl. OpenAI, Anthropic, Gemini, Bedrock, VertexAI, OpenRouter, Ollama, Mistral, DeepSeek, xAI, Perplexity, and any OpenAI-compatible endpoint. | Whatever you implement; each provider = new Faraday client + new parsing code. No free additions. |
| Chat/completions support | Yes, via per-SDK methods (`chat`, `messages`, `stream_generate_content`) — method names differ per provider and are hardcoded in `client_method_name`. | Unified `RubyLLM.chat.ask`. | Must implement per-provider request/response mapping yourself. |
| Streaming support | Yes, but each backend has its own chunk parser (`stream_handler` for OpenAI/Anthropic; inline loop for Gemini). OpenAI tool-call deltas need custom `deep_streaming_merge`; Anthropic needs a `content_block_*` state machine. | Unified streaming block yielding `RubyLLM::Chunk` with normalized `content`, `tool_calls`, `tokens`, `thinking`. Provider differences hidden. | Must parse SSE per provider yourself; this is the single hardest, most error-prone part to reimplement (the existing Anthropic tool-streaming state machine is evidence). |
| Tool/function calling | Yes. Canonical format is OpenAI's; Anthropic converts to/from it (`anthropic/tools.rb`, `preceding_conversation_messages`). Gemini tool calling is **not wired into streaming**. Parallel-call splitting is hand-rolled for OpenAI. | `RubyLLM::Tool` subclasses with `desc`/`params`; `chat.with_tool(...)`. Handles streaming + tools, including the pause/resume phases. | Must implement schema emission, argument accumulation, and per-provider format translation — i.e. rebuild `Toolbox` + `AIBackend::Tools` + the conversion code. |
| Structured outputs / JSON schema | Only JSON *mode* (`response_format: {type: "json_object"}` / `response_mime_type`), and only for autotitling. No JSON-schema. Backend-conditional in `AutotitleConversationJob`. | `RubyLLM::Schema` (`with_schema(...).ask`) for true structured output across providers. | Must map each provider's structured-output param yourself. |
| Embeddings | Not used; `tiktoken_ruby` is a dead dep. | `RubyLLM.embed` available if needed later. | Would have to add HTTP calls per provider if ever needed. |
| Multimodal support | Vision input (images + extracted PDF text) implemented per provider in `preceding_conversation_messages`. Image *output* via direct `OpenAI::Client.images.generate` in `Toolbox::Image`, bypassing the abstraction. No audio/video. | Vision, audio, documents, image generation (`RubyLLM.paint`) unified. Would let `Toolbox::Image` stop depending on a specific provider's client. | Must implement per-provider content-part formats for vision and a separate image-gen client. |
| Rails integration fit | Hand-rolled: `AIBackend` subclasses, `APIService` driver enum, encrypted tokens, `Current` for user/message. No ActiveRecord integration from the SDKs. | `acts_as_chat` ActiveRecord mixin, install generator, model registry, `Rails.env`-aware. Would replace the `AIBackend` layer but `APIService`/`LanguageModel`/credential model can stay. | Fully under your control but you write all the glue. |
| Error handling and retries | Hand-rolled in `GetNextAIMessageJob`: rescues SDK-specific + Faraday classes, 3-attempt linear backoff, `retry_on WaitForPrevious` exponential. 429 treated as billing (not retried). No SDK-level retry middleware configured. | Unified `RubyLLM::Error` hierarchy mapping HTTP statuses; automatic Faraday retry middleware for timeouts/429/5xx (configurable `max_retries`, backoff). | You must build the error hierarchy, retry/backoff, and rate-limit handling from scratch — the most critical correctness risk. |
| Authentication/configuration | `APIService#effective_token` with ActiveRecord encryption + app default keys; per-SDK client construction in each `AIBackend::*#initialize`. Three different client constructors. | Single `RubyLLM.configure` block; per-request API keys also supported. Would need an adapter to feed `APIService.effective_token` per request. | You own the auth header construction per provider (trivial but per-provider). |
| Testability | Custom `TestClient::OpenAI/Anthropic/Gemini` fakes swapped via `Rails.env.test?`; system tests can't mock (separate process). Fakes are coupled to SDK method names. | Public surface is small and stable (`chat.ask`); can stub at that boundary or use VCR-style recording. Eliminates per-SDK fakes. | You stub your own internal client objects — easiest to test, but you also own correctness of the fakes. |
| Observability/logging | `Rails.logger.info` scattered; token counts persisted on `Message`; `RUBYLLM_DEBUG`-style flag absent. No structured instrumentation. | `RubyLLM::Instrumentation` hooks + `RUBYLLM_DEBUG`. Token usage exposed on every `Chunk`/`Message`. | You build logging/instrumentation from scratch. |
| Maintainability | Three SDKs to upgrade independently (already on `ruby-anthropic` 0.4.0, a young gem), plus a ~600-line hand-rolled normalization layer that duplicates what a unified SDK would provide. Monkey-patches `Gemini::Errors` in two files. | One gem, one upgrade path, one interface. Provider quirks maintained upstream. | One codebase to maintain, but *you* are the upstream for every provider quirk, model change, and streaming format update. |
| Vendor lock-in | Moderate. Code is *written* to be multi-provider, but the OpenAI tool-call format is canonical and image gen is hardcoded to OpenAI. | Low by design; normalized interface. Risk: lock-in to RubyLLM's API surface instead. | Lowest *external* lock-in, highest *internal* lock-in to your own abstraction. |
| Migration effort | N/A (current state). | Medium. Map `AIBackend::*` → `RubyLLM.chat` with per-request model+key from `LanguageModel`/`APIService`; rewrite `stream_next_conversation_message` to the `ask` block; port `Toolbox::*` to `RubyLLM::Tool` (the reflection-based schema generator can be dropped in favor of `RubyLLM::Tool` DSL); replace `TestClient::*` with stubs of the small RubyLLM surface; replace `Toolbox::Image`'s direct OpenAI call with `RubyLLM.paint`. `GetNextAIMessageJob`'s error rescue list simplifies to `RubyLLM::Error` subclasses. Largest risk: preserving the exact streaming/broadcast throttle and cancellation behavior. | High. Reimplement streaming SSE parsing, tool-call accumulation, per-provider message formatting, retry/backoff, and the image-gen client — roughly the contents of `ai_backend/**` plus the job's error logic — while keeping behavior identical. |
| Code complexity | High. ~600 LOC across `ai_backend/**` plus three SDKs in the bundle, with provider conditionals leaking into the job and `AutotitleConversationJob`. | Low at the call site; complexity moves into the gem. Net reduction in app LOC. | Medium–high in-app; you shed 3 gems but grow a custom `AIBackend`-equivalent that must match SDK behavior. |
| Performance/runtime overhead | Three SDKs each bring their own Faraday stack; minimal runtime overhead beyond HTTP. `tiktoken_ruby` C extension loads for no benefit. | One Faraday stack, three total gem deps (Faraday, Zeitwerk, Marcel). Comparable overhead. | Minimal (one Faraday stack you control), but no built-in connection pooling/retry middleware unless you add it. |
| Long-term maintenance burden | High and growing: each provider SDK evolves independently, streaming/tool formats drift, and the app must track all three. Already shows strain (Anthropic tool streaming state machine, OpenAI parallel-call splitting, double monkey-patch of `Gemini::Errors`). | Bounded: track one gem's changelog. Provider changes are upstreamed for you. | Unbounded: every provider API change, new model, or streaming-format tweak is a ticket in *this* repo. |

---

## Custom Code Assessment

The question is whether dropping the three SDKs in favor of direct Faraday HTTP calls and internal abstractions would be *more efficient* than either the status quo or RubyLLM.

**Feature surface actually used is small** — chat, streaming, tools (OpenAI-shape), JSON mode, vision input, and image generation. Embeddings/audio/moderation are absent. In principle this is a tractable amount to implement directly.

**However, the app has *already* built the custom abstraction layer** (`AIBackend` + per-provider subclasses + `Tools` concerns + `Toolbox` reflection + `TestClient` fakes). Going "custom" would not eliminate this layer; it would only push its lower boundary down from "SDK method call" to "raw HTTP + SSE parsing." The savings would be limited to removing three gems and their client-construction boilerplate, while the cost would be:

- **Streaming** — the riskiest item. The existing code already contains non-trivial logic: OpenAI's `deep_streaming_merge` for fragmented tool-call deltas and Anthropic's `content_block_start/delta/stop` state machine with incremental `JSON.parse` of `partial_json`. Reimplementing SSE splitting and these state machines correctly, per provider, with no off-the-shelf retry middleware, is real ongoing risk.
- **Retries / rate limits** — currently hand-rolled in the job with no SDK-level retry. Custom code keeps this burden and removes the option to lean on Faraday retry middleware that SDKs/RubyLLM configure. 429 is today mis-classified as a billing error rather than retried; custom code doesn't fix that unless you deliberately build it.
- **Error handling** — the job rescues SDK-specific exception classes by name. Custom code gives a cleaner, owned error hierarchy, but you must build and keep it aligned with provider HTTP statuses yourself.
- **Schema validation / tool calling** — `Toolbox`'s reflection-based schema generator and the OpenAI↔Anthropic format conversion are already bespoke and provider-specific. Custom code preserves them as-is (no change) but inherits all future format drift.
- **Future model/provider changes** — every new model capability (e.g. Anthropic's evolving tool-use streaming events, OpenAI's `stream_options.include_usage`) becomes a maintenance task in this repo rather than an upstream gem update. The current code already lags (Gemini tool calling isn't wired into streaming; `max_completion_tokens` is hardcoded to 2000 with a TODO).
- **Amount of code to replace** — roughly the contents of `app/services/ai_backend/**` (~600 LOC) plus the provider-specific branches in `GetNextAIMessageJob` and `AutotitleConversationJob`, plus a new image-generation HTTP client to replace `Toolbox::Image`'s `OpenAI::Client` usage. This is *more* code than the SDK calls it would remove.

**Conclusion on custom code:** It is **not** the more efficient path. The app's requirements are provider-specific enough (three different message formats, three different streaming protocols, tool-format translation, image generation) that "custom code" means rebuilding, in this repo, exactly the layer that RubyLLM already maintains upstream — while forfeiting retry middleware, a tested error hierarchy, and a model registry. The one genuine advantage of custom code — a single owned interface — is the same advantage RubyLLM provides, but without the maintenance burden. Custom code would simplify the dependency graph (shed 3–4 gems) but complicate the application code and its long-term upkeep. If the goal were to support a *single* provider only, custom code would be attractive; for this multi-provider app, it is the highest-effort, highest-long-term-burden option.

---

## Recommendation

1. **Preferred: migrate to RubyLLM.** It matches the app's actual feature surface (chat, streaming, tools, JSON schema, vision, image generation), collapses three SDKs and the hand-rolled `AIBackend` normalization into one maintained interface, supplies retry middleware and a unified error hierarchy, and lets `Toolbox::Image` stop depending on a hardcoded `OpenAI::Client`. The existing `APIService`/`LanguageModel`/credential model and the Turbo-streaming job skeleton can remain; the migration is mostly rewriting the `AIBackend::*` call sites and the `TestClient` fakes. Remove the unused `tiktoken_ruby` gem regardless.
2. **Acceptable fallback: keep the current SDKs**, but pay down the highest-friction debt: stop branching on backend class in `AutotitleConversationJob` (route JSON mode through `AIBackend`), centralize the `Gemini::Errors::ConfigurationError` monkey-patch to one file, wire Gemini tool calling into streaming, and add SDK-level retry middleware so 429s are retried instead of shown as billing errors.
3. **Not recommended: custom code**, unless the app is deliberately narrowing to a single provider. For the current multi-provider scope it duplicates existing work and maximizes long-term maintenance burden.
