# LLM Catalog Default Model Refresh Design

**Date:** 2026-03-06

**Status:** Approved

## Goal

Refresh the LLM catalog to the current model lineup, remove compatibility-oriented fallback behavior, and introduce a single site-wide default `model_ref` that overrides the catalog default for new conversations and for agent runs that do not set `prefer`.

## Summary Of Decisions

- The catalog keeps provider/model/capability metadata as the source of truth.
- The catalog now has a single top-level `default_model_ref`.
- Provider-local `default_model` entries are removed.
- Runtime selection never auto-switches providers to "help."
- Provider call failures remain hard errors.
- A site-wide default model is stored in `Account.instance.settings["llm"]["default_model_ref"]`.
- The site-wide default applies only when no explicit conversation `model_ref` exists and the agent does not set `prefer`.
- The local mock provider is renamed from `local` to `dev`.
- `local` is reserved for future real local inference providers such as Ollama, vLLM, or LM Studio.
- No compatibility layer is kept for old provider keys, old model refs, or old usage buckets.

## Catalog Shape

The catalog continues to live in `config/llm/providers.yml`, but it changes from provider-local defaults to a single top-level default:

```yaml
version: 1
default_model_ref: "openai/gpt-5.4"
providers:
  openai:
    ...
    models:
      gpt-5.3-instant:
        api_model: "gpt-5.3-chat-latest"
      gpt-5.4:
        api_model: "gpt-5.4"
  codex_subscription:
    ...
    models:
      gpt-5.3-codex:
        api_model: "gpt-5.3-codex"
      gpt-5.4:
        api_model: "gpt-5.4"
      gpt-5.4-extra-high:
        api_model: "gpt-5.4"
        request_defaults:
          reasoning_effort: xhigh
  openrouter:
    ...
  dev:
    ...
```

### OpenAI catalog entries

The OpenAI provider exposes:

- `openai/gpt-5.3-instant` -> `api_model: gpt-5.3-chat-latest`
- `openai/gpt-5.4` -> `api_model: gpt-5.4`

These remain OpenAI-native models, not aliases to other providers.

### Codex catalog entries

The Codex subscription provider exposes:

- `codex_subscription/gpt-5.3-codex`
- `codex_subscription/gpt-5.4`
- `codex_subscription/gpt-5.4-extra-high`

`gpt-5.4-extra-high` is a distinct selectable `model_key` that still sends `api_model: gpt-5.4`, but uses `request_defaults.reasoning_effort: xhigh`.

Codex capability metadata must match real implementation status. Codex supports tool calling via the Responses API path, so Codex catalog entries should set `tools.tool_calling: true`.

### OpenRouter catalog entries

The OpenRouter provider key is finalized as `openrouter`.

`model_key` values are stable slugs derived from the upstream model identifier, while `api_model` preserves the upstream string exactly. The initial lineup is:

- `openrouter/openai-gpt-5.4-pro` -> `api_model: openai/gpt-5.4-pro`
- `openrouter/openai-gpt-5.4` -> `api_model: openai/gpt-5.4`
- `openrouter/openai-gpt-5.3-chat` -> `api_model: openai/gpt-5.3-chat`
- `openrouter/openai-gpt-5.3-codex` -> `api_model: openai/gpt-5.3-codex`
- `openrouter/anthropic-claude-opus-4.6-nitro` -> `api_model: anthropic/claude-opus-4.6:nitro`
- `openrouter/z-ai-glm-5-nitro` -> `api_model: z-ai/glm-5:nitro`
- `openrouter/minimax-minimax-m2.5-nitro` -> `api_model: minimax/minimax-m2.5:nitro`
- `openrouter/moonshotai-kimi-k2.5-nitro` -> `api_model: moonshotai/kimi-k2.5:nitro`
- `openrouter/qwen-qwen3.5-plus-02-15` -> `api_model: qwen/qwen3.5-plus-02-15`

OpenRouter capability metadata is only as reliable as our curation. For the approved/curated OpenRouter lineup, we intend tool calling to work, so those entries should set:

- `input.text: true`
- `input.image: false` (conservative unless explicitly validated)
- `tools.tool_calling: true`

### Dev provider

The mock provider is renamed to:

- `dev/mock-model`

It remains development/test-only.

The `local` provider name is left unused so future real local inference providers can use that namespace cleanly.

## Model Selection Semantics

### Selection precedence

Runtime model resolution uses this fixed precedence:

1. Explicit conversation or node `model_ref`
2. Agent `prefer`
3. Site default `Account.instance.settings["llm"]["default_model_ref"]`
4. Catalog top-level `default_model_ref`

There is no provider-level default selection and no "first usable provider" behavior.

### Hard-error behavior

The system must not auto-switch providers because provider changes can carry materially different cost and behavior.

Policy:

- If a stored conversation `model_ref` no longer exists, hard error and require re-selection.
- If the site default no longer exists in the catalog, ignore that override and use the catalog top-level `default_model_ref`.
- If the site default still exists but is unusable because the provider is disabled, credentials are missing, or the environment does not allow it, hard error.
- If the catalog top-level `default_model_ref` is unusable, hard error.
- If the provider call itself fails, hard error.

The only automatic fallback is from an invalid site override to the catalog top-level default. There is never an automatic provider swap after a runtime/provider error.

## Site-Wide Default Model

### Storage

The site-wide override is stored in:

- `Account.instance.settings["llm"]["default_model_ref"]`

This value is optional. If blank or absent, the system uses the catalog top-level `default_model_ref`.

### Validation

When saving the site-wide default model:

- it must be a complete `model_ref`
- it must exist in the current catalog
- it must be enabled in the current environment
- it must meet credential requirements

The settings UI only offers currently usable models so invalid values are blocked before persistence.

### UI

The current `System Settings -> LLM Providers` page gains a top card for "Default model":

- a `<select>` listing currently usable models
- an empty option labeled `Use catalog default`
- current effective source text:
  - `Site override: openai/gpt-5.4`
  - or `Catalog default: openai/gpt-5.4`
- a warning when the stored override no longer exists in the catalog and is being ignored

This is a site-wide setting, not a per-provider setting.

## Conversation Creation Semantics

When a new conversation is created, the app resolves the initial default model once and persists it directly into conversation metadata:

- first from agent `prefer`
- otherwise from the site-wide default override
- otherwise from the catalog top-level `default_model_ref`

The resolved `model_ref` is written into `conversation.metadata["llm"]["model_ref"]` at creation time.

This keeps new conversations stable:

- they do not silently drift when the site default changes later
- the composer's initial selected value matches the runtime selection
- future turns keep using the same conversation-level model until the user changes it

## Compatibility And Cleanup

This design intentionally does not preserve runtime compatibility for older data.

The implementation removes:

- provider-key alias normalization such as `openrouter -> openrouter`
- usage-stat aggregation that merges legacy provider keys
- legacy tests that assert old refs are transparently fixed up
- rename migrations added only to preserve existing `llm_providers` rows
- resolver logic that chooses the first available provider when no explicit selection is found

This work assumes the database can be reset after acceptance.

## Testing Strategy

### Catalog tests

- require top-level `default_model_ref`
- reject provider-local `default_model`
- assert the new OpenAI/Codex/OpenRouter/dev model sets
- assert `dev/mock-model` replaces `local/mock-model`

### Resolver tests

- explicit conversation `model_ref` wins
- agent `prefer` wins over site default
- site default wins over catalog top-level default
- invalid site default ref falls back to catalog top-level default
- existing-but-unusable site default hard errors
- no implicit provider fallback occurs

### Integration tests

- settings page saves and clears the site default model
- new conversation creation persists the resolved default `model_ref`
- composer initially selects the stored conversation model
- missing credentials hide unusable models from both the picker and site-default selector

## Risks

- Introducing a top-level `default_model_ref` requires catalog validation changes and resolver simplification at the same time.
- Persisting the default `model_ref` during conversation creation changes the creation path and needs tight test coverage.
- Removing compatibility code is correct for the requested policy, but it means stale local data will fail loudly until the database is reset.
