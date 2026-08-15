# RubyLLM Migration Plan — Phased, Feature-Flagged, Non-Breaking

A 7-phase plan (plus one mid-stream spike PR) to migrate the HostedGPT Rails app
from three per-provider AI SDK gems (`ruby-openai`, `ruby-anthropic`, `gemini-ai`)
to the unified `ruby_llm` gem (pinned `~> 1.16.0`), behind a feature flag so the
old path remains runnable end-to-end until a separate cleanup PR.

Each phase is a separately reviewable PR. Old backends, old tests, and old gems
are **not removed** until Phase 7. The plan is structured so that flipping the
flag on at any point during Phases 1–5 only reroutes code paths the new backend
actually supports; everything else silently uses the old SDK path.

## Grounding references

- Assessment: `docs/plans/ai-integration-assessment_glm52.md`
- Goal prompt: `docs/plans/goal.md`
- Reference branch A (hard cutover, **do not** adopt its architecture):
  `add-in-rubyllm-ai` — commits `280b2c5`, `bd373e7`, `6866d0c`, `7fdc00b`.
  Reusable: `InterceptedTool` / `ToolCallIntercepted` pattern, `set_provider_key` /
  `set_provider_base` Groq handling, `RubyLLM::Content.new(text, attachments)`
  multimodal helper, `sanitize_content` replay-stripping, `TestChat` fake shape.
- Reference branch B (feature-flagged, **adopt** its architecture):
  `add-rubyllm-with-feature-flag` — single squashed commit `fe2e7ef`.
  Reusable: `AIBackend::RubyLLM < AIBackend` parallel-class shape,
  `provider_slug` / `ruby_llm_context` / `provider_for_url`, `TestClient::RubyLLM`
  fake, `elsif ai_backend.class == AIBackend::RubyLLM` job-branch pattern,
  `Feature.rubyllm?` wiring (we rename the flag — see below), `inflections.rb`
  LLM acronym.

When a citation says "take ONLY this file/pattern, not the commit," that is
literal: `add-in-rubyllm-ai` commit `bd373e7` deletes the old backends, flattens
`APIService#ai_backend`, edits READMEs, and adds docs — **all out of scope** for
our phases. Extract the named class/method only.

---

## Out of scope (explicit, to prevent freelancing)

- No Settings UI view for the per-user flag toggle (the preference field is made
  writable; a future Settings view can surface it without rework).
- No `config/models.json` registry import, no `models:import_rubyllm` rake task,
  no `LanguageModel.import_rubyllm_registry`. `models.yml` stays the source of
  truth; `LanguageModel.api_name` is passed to RubyLLM with
  `assume_model_exists: true`, which bypasses RubyLLM's model registry.
- No DB migration. `User#preferences` is a serialized JSON column; the flag
  rides on the existing `preferences[:feature][:use_ruby_llm]` path that
  `Feature.enabled?` already reads.
- No removal of existing gems, backends, test clients, or per-provider tests
  until Phase 7.
- No changes to `Toolbox::*` tool classes themselves (only to how
  `AIBackend::RubyLLM` registers them with RubyLLM).
- No new rake tasks, no README changes, no docs changes bundled with functional
  PRs (this plan doc is the only docs artifact).

Existing test files that must NOT be edited through Phase 6:
`test/services/ai_backend/open_ai_test.rb`, `anthropic_test.rb`, `gemini_test.rb`,
`test/jobs/get_next_ai_message_job_openai_test.rb`,
`get_next_ai_message_job_anthropic_test.rb`,
`get_next_ai_message_job_gemini_test.rb`,
`test/support/test_client/open_ai.rb`, `anthropic.rb`, `gemini.rb`.
New tests go in `test/services/ai_backend/ruby_llm_test.rb`,
`test/jobs/get_next_ai_message_job_ruby_llm_test.rb`,
`test/jobs/autotitle_conversation_job_ruby_llm_test.rb`,
`test/services/ai_backend/ruby_llm/tool_interception_test.rb` (Phase 4.5).

---

## The flag wiring (the spine — specified once, referenced by every phase)

### Flag name and location

The repo's app-wide config is **`config/options.yml`** (loaded at
`config/application.rb:19` via `config_for(:options)`). There is no
`config/settings.yml`. All feature flags live under `shared.features:`
(lines 36–48). The `default_to` helper is ERB-defined at the top of that file.

Add under `shared.features:` (after `password_reset_email`, line 48):

```yaml
  use_ruby_llm: <%= ENV["USE_RUBY_LLM"] || default_to(false) %>
```

Flag name is `use_ruby_llm` (snake_case) so `Feature.use_ruby_llm?` dispatches
via the existing `method_missing` at `feature.rb:48-54` → `enabled?("use_ruby_llm")`.

### Per-user preference override (writable, no UI yet)

`Feature.enabled?` (`feature.rb:30-42`) reads
`Current.user.preferences.dig(:feature, feature.to_sym)` **first**, falling back
to the global. `User#preferences` is serialized JSON via `JsonSerializer`
(`user.rb:30`). Existing permitted preference keys are `:nav_closed`,
`:dark_mode` at `users_controller.rb:62` and `settings/people_controller.rb:19`.

To make the flag per-user-writable, permit the nested key in both controllers:

- `app/controllers/users_controller.rb:62`:
  `params.require(:user).permit(preferences: [:nav_closed, :dark_mode, feature: [:use_ruby_llm]])`
- `app/controllers/settings/people_controller.rb:19`:
  `preferences: [:dark_mode, feature: [:use_ruby_llm]]`

`Feature.enabled?` already reads the nested shape, so no model change is needed.
A future Settings view can surface it with no rework.

### CRITICAL: `preferences` writes must merge, not replace (Phase 1 fix)

`JsonSerializer` (`app/serializers/JsonSerializer.rb`) is a plain serializer —
it does **not** merge. The existing nav-toggle at
`messages/_main_column.html.erb:16` sends a partial hash
`{nav_closed: ...}` through `UsersController#update`, which **replaces the whole
`preferences` column**, silently wiping `dark_mode` (masked by `with_defaults` in
the reader at `user.rb:33`) and any `feature` key. If a dogfooder flips
`use_ruby_llm` on, the next nav-toggle clobbers it.

This is a latent bug in the existing code that directly affects our plan.
**Phase 1 must fix it** by merging in both write paths:

- `UsersController#update` (`users_controller.rb:29-36`): read
  `Current.user.preferences`, deep-merge the incoming `user_params[:preferences]`,
  write the merged hash.
- `Settings::PeopleController#update` (`settings/people_controller.rb:7-13`):
  same merge against `Current.person.user.preferences`.

This is in-scope as "make the preference field writable" — without it, the
write is not durable. Frame it as fixing a latent bug, not a feature.

### Dispatch with the `supports_driver?` guard (and why)

`app/models/api_service.rb:23-32` currently:

```ruby
def ai_backend
  case driver
  when "openai"    then AIBackend::OpenAI
  when "anthropic" then AIBackend::Anthropic
  when "gemini"    then AIBackend::Gemini
  end
end
```

Phase 1 adds one line before the `case`:

```ruby
def ai_backend
  return AIBackend::RubyLLM if Feature.use_ruby_llm? && AIBackend::RubyLLM.supports_driver?(driver)
  case driver
  when "openai"    then AIBackend::OpenAI
  when "anthropic" then AIBackend::Anthropic
  when "gemini"    then AIBackend::Gemini
  end
end
```

**Why the guard exists (reasoning to preserve in the plan):** without it, a
dogfooder who flips the flag on during Phase 2 (OpenAI-only) and chats with
Claude would hit `NotImplementedError` inside `AIBackend::RubyLLM`. With the
guard, unsupported drivers silently use the old SDK path — the flag is a dial,
not a footgun. `supports_driver?` returns `false` in Phase 1,
`["openai"].include?(driver)` in Phase 2, adds `"anthropic"` and `"gemini"` in
Phase 3, returns `true` for all in Phase 6. The guard is removed in Phase 7.

This is the **only** runtime guard beyond the bare boolean. It is deliberately
per-driver, not per-code-path — keeping dispatch in one place
(`APIService#ai_backend`) avoids the scattered `if Feature.rubyllm?` checks that
made the `add-rubyllm-with-feature-flag` branch "not meet phased needs."

### Initializer (minimal, dummy keys are intentional)

`config/initializers/ruby_llm.rb` (new):

```ruby
RubyLLM.configure do |config|
  config.openai_api_key    = ENV["DEFAULT_OPENAI_KEY"]    || "dummy-key-for-test"
  config.anthropic_api_key = ENV["DEFAULT_ANTHROPIC_KEY"] || "dummy-key-for-test"
  config.gemini_api_key    = ENV["DEFAULT_GEMINI_KEY"]    || "dummy-key-for-test"
  config.logger            = Rails.logger
  config.request_timeout   = Rails.env.production? ? 120 : 30
end
```

The dummy keys are **intentional**: they let RubyLLM boot without env vars.
Real per-request keys are injected via `RubyLLM.context` inside
`AIBackend::RubyLLM` — not in the initializer. Do **not** "fix" this by raising
on missing keys. Reference: `add-in-rubyllm-ai` commit `280b2c5`.

### Inflection

`config/initializers/inflections.rb` — add `inflect.acronym "LLM"` so
`AIBackend::RubyLLM` constantizes correctly. Reference: `add-rubyllm-with-feature-flag`
commit `fe2e7ef`.

### Gemfile pin

`Gemfile` — add `gem "ruby_llm", "~> 1.16.0"`. This is **patchlocked**
(`>= 1.16.0, < 1.17.0`) for the duration of the migration, to block surprise
1.17 behavior mid-migration. Loosen to `~> 1.16` in Phase 7. Do **not** remove
`ruby-openai`, `ruby-anthropic`, `gemini-ai`, or `tiktoken_ruby` until Phase 7
(`ruby-openai` may need to remain past Phase 7 if image gen wasn't migrated —
see Phase 6 and Phase 7 notes).

---

## Phase 1 — Scaffolding (PR 1)

**Scope:** Flag, gem, initializer, inflection, empty backend shell, empty
TestClient shell, `supports_driver?` returns `false`, **and the `preferences`
merge fix (C1)**. CI green. No behavior change possible even if the flag is
flipped, because `supports_driver?` is `false` for every driver.

**Files:**

- `Gemfile` / `Gemfile.lock` — add `ruby_llm`, `~> 1.16.0`. Remove nothing.
- `config/options.yml` — add `use_ruby_llm` line under `shared.features:`.
- `config/initializers/ruby_llm.rb` — new (above).
- `config/initializers/inflections.rb` — add LLM acronym.
- `app/services/ai_backend/ruby_llm.rb` — new, shell:
  - `class AIBackend::RubyLLM < AIBackend`
  - `class ConfigurationError < StandardError; end` (gives the job a concrete
    class to rescue even before functional code lands — matches
    `add-rubyllm-with-feature-flag` `fe2e7ef`).
  - `class RateLimitError < StandardError; end`
  - `def self.supports_driver?(driver) ; false ; end`
  - `def self.client ; Rails.env.test? ? ::TestClient::RubyLLM : ::RubyLLM ; end`
  - All interface methods (`get_oneoff_message`,
    `stream_next_conversation_message`, `set_client_config`,
    `client_method_name`, `preceding_conversation_messages`, `stream_handler`,
    `format_parallel_tool_calls`) raise `NotImplementedError`.
- `test/support/test_client/ruby_llm.rb` — new, shell (class skeleton mirroring
  `test/support/test_client/open_ai.rb` structure, methods stubbed).
- `app/models/api_service.rb:23` — add the
  `return AIBackend::RubyLLM if ...` line (dead code since
  `supports_driver?` is false).
- `app/controllers/users_controller.rb:62` — permit
  `feature: [:use_ruby_llm]` in `user_params`.
- `app/controllers/settings/people_controller.rb:19` — permit
  `feature: [:use_ruby_llm]` in `person_params`.
- **C1 fix:** `app/controllers/users_controller.rb:29-36` and
  `app/controllers/settings/people_controller.rb:7-13` — merge incoming
  `preferences` with existing before write. Frame as fixing a latent bug.

**Tests:**

- `test/models/feature_test.rb` — add one test asserting `Feature.use_ruby_llm?`
  reads `options.yml` default (false) and overrides from
  `user.preferences[:feature][:use_ruby_llm]`. Reference pattern:
  `test/models/feature_test.rb:34-48`.
- `test/services/ai_backend/ruby_llm_test.rb` — new, asserts `supports_driver?`
  is false for all drivers and that `APIService#ai_backend` still returns old
  classes with flag off.
- Add a test proving the preferences-merge fix: a user with
  `preferences: {dark_mode: "light", feature: {use_ruby_llm: true}}` who
  PATCHes `{nav_closed: true}` ends up with all three keys preserved.

**Acceptance:** `bin/rails test` green. `Feature.use_ruby_llm?` returns false by
default. No production code path can reach `AIBackend::RubyLLM`. Preferences
writes no longer clobber unrelated keys.

**Reference code:** initializer from `add-in-rubyllm-ai` `280b2c5`; inflection
from `add-rubyllm-with-feature-flag` `fe2e7ef`; class skeleton from
`add-rubyllm-with-feature-flag` `app/services/ai_backend/ruby_llm.rb` (strip
functional methods).

---

## Phase 2 — Plain text chat, OpenAI only (PR 2)

**Scope:** `AIBackend::RubyLLM` implements `get_oneoff_message` and
`stream_next_conversation_message` for the `openai` driver, text-only, no tools,
no images, no PDFs. Streaming + token-counting parity with `AIBackend::OpenAI`.
`supports_driver?` returns `["openai"].include?(driver)`.

This is why `supports_driver?` exists: with flag on and driver `anthropic` in
Phase 2, `APIService#ai_backend` returns `AIBackend::Anthropic` (old path), so
`test_language_model` uses the old `AIBackend::Anthropic.test_execute`. No gap.
Do **not** implement `test_execute` for non-OpenAI providers in this phase.

**Files:**

- `app/services/ai_backend/ruby_llm.rb` — implement:
  - `initialize` — call `super`, resolve `@api_service`, `@token`,
    `@api_name` from `@assistant.language_model`. Do NOT construct a client
    (RubyLLM is a module).
  - `ruby_llm_context` —
    `RubyLLM.context { |c| c.openai_api_key = token; c.openai_api_base = url if url != APIService::URL_OPEN_AI }`
    (handles Groq — same logic as `add-in-rubyllm-ai` `set_provider_base`,
    commit `bd373e7`).
  - `build_chat` —
    `ruby_llm_context.chat(model: @api_name, provider: :openai, assume_model_exists: true)`.
  - `get_oneoff_message(instructions, messages, params)` —
    `chat.with_instructions(full_instructions).ask(preceding_messages(messages).last[:content], **params)`.
    Return `response.content`.
  - `stream_next_conversation_message(&chunk_handler)` —
    `chat.complete { |chunk| stream_handler.call(chunk, chunk_handler) }`.
    Capture `chunk.input_tokens`/`chunk.output_tokens` onto `@message`
    **inside** the stream proc (same timing as `AIBackend::OpenAI#stream_handler`
    at `open_ai.rb:77-109`), not after the stream completes. Raise
    `AIBackend::RubyLLM::ConfigurationError` on `RubyLLM::UnauthorizedError`.
    Raise `Faraday::ParsingError` on blank response (preserves the job's
    existing blank-response rescue at `get_next_ai_message_job.rb:86`).
  - `stream_handler` — proc yielding `chunk.content` to `chunk_handler`,
    accumulating `@stream_response_text`. Rescue
    `RubyLLM::UnauthorizedError` → `ConfigurationError`,
    `RubyLLM::RateLimitError`/`PaymentRequiredError` → `RateLimitError`.
    Re-raise `GetNextAIMessageJob::ResponseCancelled` (cooperative cancellation —
    matches `AIBackend::OpenAI#stream_handler` at `open_ai.rb:77-109`).
  - `preceding_conversation_messages` — for Phase 2, handle **text-only**
    messages (skip images/PDFs). Reuse the message-iteration shape from
    `AIBackend::OpenAI#preceding_conversation_messages` (`open_ai.rb:118-170`)
    but emit `RubyLLM::Message` / `{role:, content:}` hashes. Strip tool-call
    fields (not supported yet).
  - `self.supports_driver?` → `["openai"].include?(driver)`.
  - `self.test_execute(url, token, api_name)` — minimal OpenAI-only test-execute
    for `APIService.test_language_model` (`api_service.rb`), mirroring
    `AIBackend::OpenAI.test_execute` (`open_ai.rb:17-38`).
- `test/support/test_client/ruby_llm.rb` — implement full fake: `chat` returns a
  `Chat` double with `complete`/`ask`, class-level stubbables (`text`,
  `default_text`, `arguments`, `id`, `tokens`, `blank_response`,
  `error_to_raise`) mirroring `TestClient::OpenAI`
  (`test/support/test_client/open_ai.rb`). Reference:
  `add-rubyllm-with-feature-flag` `test/support/test_client/ruby_llm.rb`.

**Tests (new files, existing tests untouched):**

- `test/services/ai_backend/ruby_llm_test.rb` — text streaming, oneoff, token
  counting, blank response → `Faraday::ParsingError`, unauthorized →
  `ConfigurationError`, cancellation, Groq base-URL override.
- `test/jobs/get_next_ai_message_job_ruby_llm_test.rb` — mirrors
  `get_next_ai_message_job_openai_test.rb` shape but dispatches via
  `Feature.use_ruby_llm?` + `supports_driver?`.

**Acceptance:** With flag ON and driver `openai`, a text conversation streams
correctly with token counts and throttle parity (0.1s,
`get_next_ai_message_job.rb:41`). With flag OFF, `AIBackend::OpenAI` is used
(byte-identical). With flag ON and driver `anthropic`/`gemini`, old path is used
(via `supports_driver?` guard).

**Reference code:** `add-in-rubyllm-ai` `app/services/ai_backend.rb`
`build_chat`/`set_provider_key`/`set_provider_base` (commits `bd373e7`,
`7fdc00b`); `add-rubyllm-with-feature-flag` `ruby_llm.rb`
`stream_handler`/`ruby_llm_context`. Take ONLY the named methods, not the
surrounding deletions/flattenings in those commits.

---

## Phase 3 — Anthropic + Gemini/Groq text chat (PR 3)

**Scope:** Extend `AIBackend::RubyLLM` to all three drivers, still text-only.
`supports_driver?` returns `true` for all three. Provider routing via
`@api_service.driver.to_sym`.

**Files:**

- `app/services/ai_backend/ruby_llm.rb`:
  - `provider_slug` → `@api_service.driver.to_sym` (from feature-flag branch
    `ruby_llm.rb`).
  - `ruby_llm_context` →
    `config.public_send("#{provider_slug}_api_key=", token)`; base URL override
    only when non-canonical (Groq). Reference: `add-in-rubyllm-ai`
    `set_provider_key`/`set_provider_base`.
  - `build_chat` → `provider: provider_slug`.
  - `preceding_conversation_messages` — still text-only; the per-provider
    message-shape differences (Anthropic tool_result blocks, Gemini `parts`)
    **don't apply yet** since we're text-only. RubyLLM normalizes the
    text-message shape internally.
  - `self.test_execute` — branch on `provider_for_url(url)` (URL regex from
    feature-flag branch `ruby_llm.rb`).
- `test/support/test_client/ruby_llm.rb` — extend fake to simulate per-provider
  response shapes if needed (likely minimal — RubyLLM normalizes).

**Tests:**

- `test/services/ai_backend/ruby_llm_test.rb` — add Anthropic + Gemini text cases.
- `test/jobs/get_next_ai_message_job_ruby_llm_test.rb` — add Anthropic + Gemini
  streaming cases.

**Acceptance:** All three drivers stream text via `AIBackend::RubyLLM` when flag
on. Groq (openai driver, non-canonical URL) works.

**Reference code:** `add-in-rubyllm-ai` `set_provider_base` Groq handling
(commit `7fdc00b`); feature-flag branch `provider_for_url`. Take ONLY the named
methods.

---

## Phase 4 — Image/PDF attachment parity (PR 4)

**Scope:** Multimodal input (vision) in `preceding_conversation_messages` for
all three drivers, matching `AIBackend::OpenAI/Anthropic/Gemini#preceding_conversation_messages`
behavior. Images via active-storage URLs/base64; PDFs via text extraction (the
existing pattern — `pdf-reader`, no native PDF upload).

**Default and fallback:** Prefer `RubyLLM::Content.new(text, attachments)` (from
`add-in-rubyllm-ai` `bd373e7`) — it abstracts provider differences. Fall back to
the feature-flag branch's `build_image_content` per-provider switch
(`ruby_llm.rb`) only if a bounded spike shows `RubyLLM::Content` mishandles a
provider. The spike is: one test per driver confirming an image attachment
streams a vision response. If all three pass, use `RubyLLM::Content` and skip
the per-provider switch entirely.

**Files:**

- `app/services/ai_backend/ruby_llm.rb`:
  - `preceding_conversation_messages` — iterate `@conversation.messages` up to
    `@message.index`; for each message with `documents`, build
    `RubyLLM::Content.new(text, attachments)` (default path) OR provider-specific
    content-part hashes (fallback path).
  - PDF handling: `document.extract_pdf_text` inlined as a text block — same as
    both reference branches and the existing `AIBackend::OpenAI#preceding_conversation_messages`
    PDF path. No native PDF upload via RubyLLM's file API.
  - Strip `json_of_generated_image` from assistant content on replay (the
    `sanitize_content` pattern from `add-in-rubyllm-ai` `bd373e7`) — prevents
    re-streaming image payloads to the model. Scope: only applied during
    *replay* in `preceding_conversation_messages`, never to live streaming
    output.

**Tests:**

- `test/services/ai_backend/ruby_llm_test.rb` — image attachment (PNG/JPEG) for
  each driver; PDF text extraction; mixed image+text message; assistant message
  with `json_of_generated_image` is sanitized on replay.

**Acceptance:** A conversation with an uploaded image produces a vision-model
response via RubyLLM for all three drivers. PDF attachments contribute extracted
text. Parity with old backends verified by running the same conversation under
flag-off and flag-on.

**Reference code:** `add-in-rubyllm-ai` `RubyLLM::Content.new(text, attachments)`
(commit `bd373e7`); feature-flag branch `build_image_content`/
`build_multimodal_content` as fallback; `sanitize_content` from
`add-in-rubyllm-ai`. Take ONLY the named methods.

**Note:** `Toolbox::Image` (image *generation*) is NOT touched in this phase —
it still uses the raw `OpenAI::Client` path (`toolbox/image.rb:38-49`). This
phase is image *input* only.

---

## Phase 4.5 — Tool-interception pre-check (PR 4.5)

**Why a separate pre-check PR (reasoning to preserve):** Phase 5 is the
highest-risk phase because RubyLLM's tool-call streaming shape differs from each
provider's raw API, and the cleanest interception pattern (`InterceptedTool <
RubyLLM::Tool` raising from `execute(**)`) depends on RubyLLM halting its
tool-execution loop when `execute` raises. That behavior is not guaranteed by
the gem's public API contract — it's emergent. If we discover mid-Phase-5 that
the raise-from-tool pattern doesn't cleanly halt the loop, we'd have to
re-architect to the `InterceptedChat#handle_tool_calls` override (which couples
to a **private** method on `~> 1.16.0` and is fragile across gem patches).
Spiking first de-risks Phase 5 without bloating it, and produces a mergeable,
revertible test artifact rather than a throwaway scratch script.

**Scope:** A single new test file that exercises `InterceptedTool` + a
`chat.complete` call and asserts the three properties Phase 5 depends on. No
production code changes other than the minimal scaffolding needed to make the
test compile (the `InterceptedTool` class and `ToolCallIntercepted` error, both
inside `app/services/ai_backend/ruby_llm.rb` or a new
`app/services/ai_backend/ruby_llm/intercepted_tool.rb`).

**Files:**

- `app/services/ai_backend/ruby_llm.rb` (or new
  `app/services/ai_backend/ruby_llm/intercepted_tool.rb`) — add:

  ```ruby
  class AIBackend::RubyLLM::ToolCallIntercepted < StandardError; end

  class AIBackend::RubyLLM::InterceptedTool < RubyLLM::Tool
    def initialize(name:, description:, params_schema:)
      @tool_name = name
      @tool_description = description
      @params_schema = params_schema
    end
    def execute(**)
      raise AIBackend::RubyLLM::ToolCallIntercepted
    end
  end
  ```

  Pattern from `add-in-rubyllm-ai` `bd373e7` — raises from `execute` (public
  API), NOT by overriding `handle_tool_calls` (private, fragile). Take ONLY
  this class, not the rest of `bd373e7`.

- `test/services/ai_backend/ruby_llm/tool_interception_test.rb` — new, asserts:
  1. `response.tool_calls` is populated after `chat.complete` with an
     `InterceptedTool` registered.
  2. `InterceptedTool#execute` is never called (RubyLLM halts before executing).
  3. The chat does not auto-continue the conversation after a tool-call
     response.

  Uses `TestClient::RubyLLM` with `function` stubbed. If the test fails against
  `~> 1.16.0`, the spike switches to the `InterceptedChat#handle_tool_calls`
  override (from `add-rubyllm-with-feature-flag` `fe2e7ef`,
  `app/services/ai_backend/ruby_llm/intercepted_chat.rb`) and documents the
  private-API coupling in the test file.

**Acceptance:** The three assertions pass (or, if they fail, the
`InterceptedChat` fallback is adopted and the test is updated to assert the same
three properties via that path). Phase 5 can then proceed against a known-good
interception pattern.

---

## Phase 5 — Tool/function calling parity (PR 5)

**Scope:** Wire `Toolbox.tools` into `AIBackend::RubyLLM` so tool-call streaming
works for all three drivers. Preserve the existing `Toolbox.call` dispatch in
`GetNextAIMessageJob#call_tools_before_wrapping_up`
(`get_next_ai_message_job.rb:199-270`) — the job stays in control of tool
execution, RubyLLM must NOT auto-execute.

**Files:**

- `app/services/ai_backend/ruby_llm.rb`:
  - `InterceptedTool` + `ToolCallIntercepted` already exist from Phase 4.5.
  - `tool_instances` — map `Toolbox.tools` (OpenAI-format descriptors from
    `toolbox.rb:52-58`) to `InterceptedTool.new(name:, description:, params_schema:)`.
    The descriptors are already in the right shape —
    `tool.dig(:function, :name)`, `:description`, `:parameters`. Do not re-derive
    the schema. Reference: feature-flag branch `tool_instances`.
  - `stream_next_conversation_message` — **override this method on
    `AIBackend::RubyLLM`** (like `AIBackend::Gemini` does at `gemini.rb:86-109`)
    so the base flow at `ai_backend.rb:27-49` is not used. The base flow calls
    `format_parallel_tool_calls(@stream_response_tool_calls)` at `ai_backend.rb:45`,
    and the `AIBackend::Tools` concern declares it with `raise NotImplementedError`
    at `ai_backend/tools.rb:46` — overriding the method sidesteps that path.
    Register tools via `chat.with_tool(*tool_instances)` only if
    `@assistant.language_model.supports_tools?`. Catch `ToolCallIntercepted` (or
    inspect `response.tool_calls`) and format tool calls into the existing
    canonical OpenAI shape
    `{index:, type:"function", id:, function:{name:, arguments: JSON}}` via a
    `format_tool_calls` helper. Return the array so the job's existing
    `@message.content_tool_calls = tool_calls` path
    (`get_next_ai_message_job.rb:52`) works unchanged.
  - `format_parallel_tool_calls` — **still implement** as a defensive identity
    (`content_tool_calls`) so the `AIBackend::Tools` concern contract is
    satisfied even though the overridden `stream_next_conversation_message`
    doesn't call it. RubyLLM returns tool calls already separated, so this is
    mostly identity (no malformed-`call_`-id splitting needed, unlike
    `AIBackend::OpenAI::Tools` at `open_ai/tools.rb:7-29`).
  - `preceding_conversation_messages` — replay prior tool messages: convert
    stored `content_tool_calls` (OpenAI shape, serialized via `JsonSerializer`
    at `message/toolable.rb:7`) into `RubyLLM::ToolCall.new(id:, name:, arguments:)`
    for assistant turns, and `role: "tool"` messages into RubyLLM's tool-result
    format. Reference: `add-in-rubyllm-ai` `bd373e7` assistant-with-tool-calls
    reconstruction. Take ONLY this replay logic, not the rest of `bd373e7`.

**Job changes (additive, exact insertion points):**

- `app/jobs/get_next_ai_message_job.rb` — add two rescue branches. Ruby
  evaluates `rescue` top-down; a generic `rescue => e` at line 101 would swallow
  `AIBackend::RubyLLM::ConfigurationError` if placed above it. **Insertion
  point:** immediately after `rescue Faraday::TooManyRequestsError` (lines
  94-97) and before `rescue WaitForPrevious` (line 98):

  ```ruby
  rescue AIBackend::RubyLLM::ConfigurationError => e
    set_generic_error(@assistant.language_model.api_service.name)
    wrap_up_the_message
    return true
  rescue AIBackend::RubyLLM::RateLimitError => e
    set_billing_error
    wrap_up_the_message
    return true
  ```

  These sit alongside the existing SDK-specific rescues
  (`get_next_ai_message_job.rb:67-97`), which still serve the old path.

- `app/jobs/autotitle_conversation_job.rb` — the
  `elsif ai_backend.class == AIBackend::RubyLLM` branch goes at line 43
  (replacing the bare `else`), with the `else` moved after it. It calls
  `get_oneoff_message` with `response_format: { type: "json_object" }` and a
  `JSON::ParserError` regex fallback. Do NOT modify the existing
  OpenAI/Anthropic/Gemini branches at lines 27-42. Reference: feature-flag
  branch `fe2e7ef`.

**Tests:**

- `test/services/ai_backend/ruby_llm_test.rb` — single tool call, parallel tool
  calls, tool-call streaming accumulation, tool-result replay in subsequent
  turn, `ToolCallIntercepted` correctly halts RubyLLM auto-execution.
- `test/jobs/get_next_ai_message_job_ruby_llm_test.rb` — full tool loop:
  assistant requests tool → job dispatches `Toolbox.call` → tool message
  persisted → assistant follow-up. Error paths: `ConfigurationError`,
  `RateLimitError`.
- `test/jobs/autotitle_conversation_job_ruby_llm_test.rb` — JSON title
  generation via RubyLLM, `JSON::ParserError` fallback.

**Acceptance:** A conversation using tools (e.g. `Toolbox::OpenMeteo`) works
end-to-end via RubyLLM for all three drivers when flag on. `Toolbox.call`
remains the single execution point. Parallel tool calls work. Old path
unchanged when flag off.

**Reference code:** `add-in-rubyllm-ai` `InterceptedTool` + `ToolCallIntercepted`
+ `format_tool_calls` (commit `bd373e7`); feature-flag branch `InterceptedChat`
as a **fallback only** (already validated in Phase 4.5). Take ONLY the named
classes/methods, not the surrounding deletions.

---

## Phase 6 — Dogfood, then flip default (PR 6)

**Scope:** Flip `use_ruby_llm` default to `true` in `config/options.yml`. Old
path still reachable via `Feature.use_ruby_llm? = false` (per-user preference or
env `USE_RUBY_LLM=false`). Optional: migrate `Toolbox::Image` from raw
`OpenAI::Client` to `RubyLLM.context.paint`.

**Files:**

- `config/options.yml` —
  `use_ruby_llm: <%= ENV["USE_RUBY_LLM"] || default_to(true) %>`.
- `app/services/toolbox/image.rb` — **optional, this phase** — replace
  `generate_with_openai_client` with `generate_with_rubyllm` using
  `RubyLLM.context.paint(model: "gpt-image-1", provider: :openai, ...)`. Keep
  `openai_client` method until Phase 7. Gate via `Feature.use_ruby_llm?` so old
  path is reachable when flag off. Reference: both branches did this —
  `add-in-rubyllm-ai` `bd373e7`, feature-flag `fe2e7ef`. Note: image gen still
  routes through OpenAI even when the chat backend is Anthropic/Gemini — same
  as the existing `generate_with_openai_client` path it sits next to.
- `app/jobs/get_next_ai_message_job.rb` — no changes (rescues from Phase 5
  already handle RubyLLM errors).

**Tests:**

- Update tests that assert flag-off-as-default to flag-on-as-default.
- `test/services/toolbox/image_ruby_llm_test.rb` — if image gen migrated.

**Acceptance:** Default new users and existing users get RubyLLM. Setting
`USE_RUBY_LLM=false` or per-user preference `feature: { use_ruby_llm: false }`
reverts to SDK path. No user-visible behavior change.

**Dogfood criteria (before merge):** All three providers tested with text,
images, PDFs, tools, autotitling, cancellation, rate-limit errors,
blank-response errors. Streaming throttle and token-count persistence confirmed
at parity.

---

## Phase 7 — Cleanup (separate future branch, not in this PR series)

**Scope:** Remove old backends, old TestClients, old gem deps, the flag itself,
and the `supports_driver?` guard. Only after confidence is high. Implemented in
a separate future branch — not bundled with functional changes, gated on
production dogfood signal from Phase 6.

**Files:**

- Delete `app/services/ai_backend/open_ai.rb`, `anthropic.rb`, `gemini.rb`,
  `open_ai/tools.rb`, `anthropic/tools.rb`, `utilities.rb`.
- Delete `test/support/test_client/open_ai.rb`, `anthropic.rb`, `gemini.rb`.
- Delete `test/services/ai_backend/open_ai_test.rb`, `anthropic_test.rb`,
  `gemini_test.rb`, `test/jobs/get_next_ai_message_job_openai_test.rb`,
  `get_next_ai_message_job_anthropic_test.rb`,
  `get_next_ai_message_job_gemini_test.rb`.
- `Gemfile` — remove `ruby-anthropic`, `gemini-ai`, `tiktoken_ruby`.
  **`ruby-openai` may need to remain** if `Toolbox::Image` was NOT migrated to
  `RubyLLM.context.paint` in Phase 6. If image gen was migrated, remove
  `ruby-openai` too. Loosen `ruby_llm` from `~> 1.16.0` to `~> 1.16`.
- `app/models/api_service.rb:23-32` — collapse `ai_backend` to
  `AIBackend::RubyLLM` (remove `supports_driver?` guard and `case driver`).
- `app/jobs/get_next_ai_message_job.rb` — remove SDK-specific rescues
  (`OpenAI::ConfigurationError`, `Anthropic::ConfigurationError`,
  `Gemini::Errors::ConfigurationError` monkey-patches at
  `get_next_ai_message_job.rb:4` and `ai_backend/gemini.rb:3`).
- `app/jobs/autotitle_conversation_job.rb:27-50` — collapse to single RubyLLM
  path.
- `config/options.yml` — remove `use_ruby_llm` flag.
- `app/controllers/users_controller.rb:62`, `settings/people_controller.rb:19` —
  remove `feature: [:use_ruby_llm]` from permitted params (or leave if other
  feature prefs land).
- `app/services/toolbox/image.rb` — remove `openai_client` and old
  `generate_with_openai_client` (if image gen was migrated in Phase 6).

**Not bundled with functional changes** — separate PR, separate review, gated
on production dogfood signal from Phase 6.

---

## Open items resolved (decisions baked into this plan)

1. **`supports_driver?` guard retained** — prevents `NotImplementedError` during
   phased dogfooding. Reasoning documented above and inline at each phase.
2. **Both `users_controller.rb:62` and `settings/people_controller.rb:19`**
   permit `feature: [:use_ruby_llm]` — validated as the only two preference
   write paths in the codebase.
3. **Phase 4.5 pre-check PR** — de-risks Phase 5 tool-interception before
   committing to the full tool-calling implementation. Reasoning documented in
   Phase 4.5.
4. **Image-gen migration stays in Phase 6 as optional** — Phase 7 notes
   `ruby-openai` may need to remain if image gen wasn't migrated.
5. **Plan location:** `docs/plans/rubyllm-migration-plan.md`.

## Gemfile pin

`ruby_llm`, `~> 1.16.0` (patchlocked) for the duration of the migration. Loosen
to `~> 1.16` in Phase 7.
