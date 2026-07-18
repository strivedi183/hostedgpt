# Goal Prompt: Assess AI Integration Design Choices for Rails App

You are working in a full Rails application repository. The app currently uses AI SDK gems for its AI functionality.

Your task is to assess three possible design directions for the app’s AI integration:

1. **Continue using the current AI SDK-based implementation**
2. **Replace the current SDKs with RubyLLM**
3. **Replace SDK/package usage with custom application code**

RubyLLM documentation is available here:

`https://rubyllm.com/`

Do not make code changes unless explicitly necessary for investigation. This is primarily an architecture and implementation assessment.

---

## Objectives

Analyze the current Rails codebase and compare the three approaches across the app’s actual AI-related requirements and implementation patterns.

Inspect the repository for:

- Current AI-related gems/packages
- Existing service objects, models, jobs, controllers, concerns, or other classes that call AI APIs
- Configuration and credential handling
- Streaming behavior, if present
- Tool/function calling, if present
- Structured output or JSON schema usage, if present
- Embeddings, if present
- Image, audio, or multimodal usage, if present
- Retry and error-handling logic
- Test coverage and mocking/stubbing patterns
- Existing abstractions around AI providers
- Coupling between business logic and specific SDK APIs

---

## Required Output

Produce  a **comparison table** covering:

1. **Current AI SDKs**
2. **RubyLLM**
3. **Custom code**

The comparison should be grounded in the actual repository implementation, not generic assumptions.

Use this table structure as a starting point:

| Category | Current AI SDKs | RubyLLM | Custom Code |
|---|---|---|---|
| Provider support |  |  |  |
| Chat/completions support |  |  |  |
| Streaming support |  |  |  |
| Tool/function calling |  |  |  |
| Structured outputs / JSON schema |  |  |  |
| Embeddings |  |  |  |
| Multimodal support |  |  |  |
| Rails integration fit |  |  |  |
| Error handling and retries |  |  |  |
| Authentication/configuration |  |  |  |
| Testability |  |  |  |
| Observability/logging |  |  |  |
| Maintainability |  |  |  |
| Vendor lock-in |  |  |  |
| Migration effort |  |  |  |
| Code complexity |  |  |  |
| Performance/runtime overhead |  |  |  |
| Long-term maintenance burden |  |  |  |

You may add, remove, or rename rows if the repository shows other categories are more relevant.

---

## Custom Code Assessment

For the custom-code option, specifically evaluate whether implementing direct API calls and internal abstractions would be a more efficient path than using SDKs or RubyLLM.

Consider:

- How many AI API features the app actually uses
- Whether the current SDKs add unnecessary abstraction or dependencies
- Whether custom code would simplify or complicate the app
- The amount of application code needed to replace the current implementation
- How provider-specific the app’s requirements are
- Risks around:
  - Streaming
  - Retries
  - Error handling
  - Rate limits
  - Schema validation
  - Tool/function calling
  - Future model changes
  - Future provider changes
- Ongoing maintenance cost

---

## Constraints

- Ground the assessment in the actual repository implementation.
- Cite specific files, classes, gems, and usage patterns where relevant.
- Do not rely only on generic AI SDK comparisons.
- Do not perform a large refactor.
- Do not add new dependencies.
- Do not remove the existing SDK implementation.
- Do not make code changes.
- Prefer concise, evidence-backed conclusions over broad speculation.

---

## Deliverable

Create a markdown report with the following structure:

```markdown
# AI Integration Design Assessment

## Executive Summary

## Current Implementation Overview

## Comparison Table

