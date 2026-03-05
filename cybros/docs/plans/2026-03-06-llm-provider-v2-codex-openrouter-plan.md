# LLM Provider v2 (Capabilities + Codex Subscription + OpenRouter) Plan
> **For Cursor Agent:** This doc is a combined **design + implementation plan**. Use it task-by-task; keep diffs small; add tests per task.

**Goal:** Refactor Cybros LLM provider layer into a capability-aware, protocol-aware system that can reliably support **Codex subscription (ChatGPT Pro/Plus)** and **OpenRouter**, while enabling **model selection in the chat composer** and correct **token estimation** per model.

**Architecture (1 paragraph):** Introduce a `ProviderAdapter` abstraction whose job is to (a) authenticate, (b) speak the wire protocol (OpenAI Chat Completions vs OpenAI Responses), (c) stream output into AgentCore’s existing stream event model, and (d) expose model capabilities. Move **provider + model catalog** (capabilities/tools/images/protocol/tokenizer hint/context window/default model/enabled/“requires credential”) into a **layered YAML config** (default shipped with the image + user override injected via Docker mount/ENV at boot). Keep **credentials** (API key / Codex OAuth tokens) in DB, encrypted, and associate them to config entries via stable `provider_key`. Extend `simple_inference` with `SimpleInference::Protocols::OpenAIResponses` (SSE + WebSocket) for reuse across projects. Ship in two phases: (1) provider refactor + Codex subscription, (2) OpenRouter.

**Tech stack:** Rails 8.2, Ruby 4.0, ActiveRecord encryption, AgentCore DAG Runtime, `vendor/simple_inference` protocol clients.

---

## Background / Research notes (key takeaways)

### OpenCode: how “Codex subscription” works

OpenCode does **not** use an OpenAI API key for Codex subscription. Instead, it performs **OAuth (PKCE / device)** against `auth.openai.com`, stores `access_token/refresh_token/expires`, and sends requests to ChatGPT’s Codex backend:

- Endpoint: `https://chatgpt.com/backend-api/codex/responses`
- Auth: `Authorization: Bearer <access_token>`
- Org plans: optional `ChatGPT-Account-Id: <account_id>`

It also refreshes tokens when expired and rewrites URLs to the Codex endpoint. See reference:

- `references/opencode/packages/opencode/src/plugin/codex.ts`

### OpenCode: OpenRouter support

OpenCode supports OpenRouter via `@openrouter/ai-sdk-provider` and injects recommended headers (`HTTP-Referer`, `X-Title`). In Cybros, OpenRouter can be treated as an OpenAI-compatible endpoint with an API key, but model capabilities and token estimation vary widely across OpenRouter models.

### Codex CLI: Responses-over-WebSocket exists (and may become preferred)

The Codex reference includes a “Responses API WebSocket” transport for `/v1/responses` and separate Realtime WS endpoints. For our coding-agent use case, the relevant piece is **Responses-over-WebSocket** (not audio Realtime).

- Mock server demonstrates WS path `/v1/responses`: `references/codex/scripts/mock_responses_websocket_server.py`
- Model metadata includes `prefer_websockets` and `input_modalities`: `references/codex/codex-rs/protocol/src/openai_models.rs`
- Codex core toggles WS when provider supports it and feature/model prefers it: `references/codex/codex-rs/core/src/client.rs`

### Cybros already has token estimation infrastructure, but Runtime default doesn’t use it

`Cybros::TokenEstimation` is already a VibeTavern-style registry + canonicalization layer, backed by AgentCore’s `TokenEstimator` (tiktoken / HF tokenizer / heuristic). However, `AgentCore::DAG::Runtime` defaults token counting to `AgentCore::Tokenization::TokenEstimator.default` (tiktoken-only). We should wire token counting to `Cybros::TokenEstimation.estimator(...)` using per-model tokenizer hints.

---

## Requirements

### Functional
- Configure multiple provider endpoints (OpenAI API key, Codex subscription, OpenRouter, local OpenAI-compatible endpoints).
- Maintain provider + model catalog in **YAML config** (default + user override; user override wins), including:
  - **provider settings**: enabled, default model, requires credential, wire_api/transport, base_url/headers.
  - **model settings**: capabilities (image/tools/protocol), tokenizer hint, context window, default reasoning effort.
- Support **chat composer model selection** (user chooses a model for the next turn).
- Support **reasoning effort variants** as distinct selectable models when the upstream supports it (e.g., treat “gpt-5.2 (high)” as a separate catalog entry from “gpt-5.2 (default)”, even if they share the same API `model` name).
- Avoid model ID collisions across providers by using a fully-qualified model reference: `provider_key/model_key`.
- Store **credentials** in DB (encrypted) and associate to config provider by `provider_key` (supports usage stats).
- **Hard-error policy for misconfiguration and provider failures**:
  - If a provider requires auth/API key and none is configured, it must not be usable in chat (hide from picker + reject if selected via stale metadata).
  - Provider failures are surfaced as hard errors requiring user correction (no silent fallback): invalid API key, OAuth expired/refresh failed, model not found, network failures/timeouts.
- Implement Codex subscription as first milestone after provider refactor.
- Implement OpenRouter as the second milestone after Codex subscription.
- Support a **local inference provider** for development/testing (e.g., Ollama or a mock OpenAI-compatible endpoint) that is only enabled/available in `development` and `test` environments.
- Usage statistics:
  - Track each user’s token usage **by model** (where “model” means the fully-qualified `model_ref`).
  - Track total token usage **by provider** across all users (Phase 0: single user, but keep the shape future-proof).

### Non-goals (for this iteration)
- Full “model editor” UI for every capability field.
- General Realtime WS (audio) support.
- Automatic model capability inference for OpenRouter across all models (we’ll provide sane defaults + overrides).

---

## Proposed configuration + data model (YAML catalog + DB credentials)

### YAML config: provider + model catalog (source of truth)

**Format:** YAML

**Layering:**
- **Default**: checked-in file shipped with the image (e.g. `config/llm/providers.yml`)
- **Override**: optional file provided at runtime (Docker mount) via env var (e.g. `CYBROS_LLM_CONFIG_PATH=/config/providers.override.yml`)
- Merge strategy: deep-merge by key; override wins; allow explicit disable/remove via `enabled: false` (no silent deletions).

**Identity / collision-avoidance:**
- Providers are keyed by `provider_key` (unique globally in the config).
- Models are keyed by `model_key` (unique within a provider).
- Fully-qualified model reference for selection/usage: **`model_ref = "#{provider_key}/#{model_key}"`**.
- `api_model` is the upstream model string sent on the wire (can be shared across variants).

**Reasoning effort variants:**
- Represent as separate models with distinct `model_key` values, potentially sharing the same `api_model`, but differing in `request_defaults.reasoning_effort` (or Responses equivalent).
  - Example: `model_key: gpt-5.2` vs `model_key: gpt-5.2-high`

**Suggested schema shape:**

```yaml
version: 1
providers:
  openai:
    display_name: OpenAI
    enabled: true
    adapter_key: openai
    base_url: "https://api.openai.com/v1"
    headers: {}
    requires_credential: true
    wire_api: responses
    transport: http_sse
    responses_path: "/v1/responses"
    default_model: "gpt-5.2"
    models:
      gpt-5.2:
        display_name: "GPT‑5.2"
        api_model: "gpt-5.2"
        capabilities:
          input: { text: true, image: true }
          tools: { tool_calling: true }
          protocol: responses
        tokenizer_hint: "gpt-5.2"
        context_window_tokens: 400000
        request_defaults:
          reasoning_effort: medium
      gpt-5.2-high:
        display_name: "GPT‑5.2 (High)"
        api_model: "gpt-5.2"
        capabilities: { ...same as above... }
        tokenizer_hint: "gpt-5.2"
        context_window_tokens: 400000
        request_defaults:
          reasoning_effort: high
  codex_subscription:
    display_name: Codex (ChatGPT Pro/Plus)
    enabled: true
    adapter_key: codex_subscription
    base_url: "https://chatgpt.com/backend-api/codex"
    headers: {}
    requires_credential: true
    credential_type: oauth_codex
    wire_api: responses
    transport: http_sse
    responses_path: "/responses"
    default_model: "gpt-5.3-codex"
    models:
      gpt-5.3-codex:
        display_name: "GPT‑5.3 Codex"
        api_model: "gpt-5.3-codex"
        capabilities:
          input: { text: true, image: true }
          tools: { tool_calling: true }
          protocol: responses
        tokenizer_hint: "gpt-5.2"
        context_window_tokens: 400000
        request_defaults:
          reasoning_effort: medium
```

### YAML catalog spec (detailed)

#### File locations and Docker injection
- **Default catalog (shipped in image)**: `config/llm/providers.yml`
- **Optional override catalog (runtime-injected)**: file path specified by `CYBROS_LLM_CONFIG_PATH`
  - Docker example: mount `./providers.override.yml:/config/providers.override.yml` and set `CYBROS_LLM_CONFIG_PATH=/config/providers.override.yml`

#### Merge semantics (default + override)
We treat the override file as a deep-merge patch keyed by provider/model keys:

- **Top level**
  - `version` must match; mismatch is a hard boot error.
- **Providers**
  - Keys are provider keys (e.g. `openai`, `codex_subscription`, `openrouter`).
  - Provider entries are deep-merged by key.
  - If a provider has `enabled: false`, it is treated as disabled in the effective catalog (even if present in default).
- **Models**
  - Under each provider, `models` entries are merged by `model_key`.
  - If a model has `enabled: false`, it is hidden from pickers and treated as invalid for sending.
- **Headers**
  - `headers` are deep-merged; override wins per header key.
- **Request defaults**
  - Provider-level `request_defaults` (optional) are deep-merged with model-level `request_defaults` (model wins).
  - This is the intended mechanism for “same `api_model` but different reasoning effort” variants:
    - Each variant is a distinct `model_key` with its own `request_defaults.reasoning_effort`.

#### Identity rules / collision avoidance
- **`provider_key`**
  - YAML key under `providers:`; must be globally unique.
  - Validation: `/\A[a-z0-9][a-z0-9_-]*\z/`
- **`model_key`**
  - YAML key under `providers.<provider_key>.models:`; unique within a provider.
  - Validation: `/\A[a-z0-9][a-z0-9._-]*\z/` (allow dots for versioned variants like `gpt-5.2-high`)
- **`model_ref`**
  - Derived: `"#{provider_key}/#{model_key}"`
  - This is the canonical identifier stored in turn metadata and usage events.
- **`api_model`**
  - The upstream model string sent to the provider. May be shared across variants.

#### Required fields (provider)
Each provider must define:
- `display_name` (string)
- `enabled` (boolean)
- `adapter_key` (string) — used to select the `ProviderAdapter` implementation
- `base_url` (string)
- `responses_path` (string, required when `wire_api: responses`)
  - OpenAI default: `"/v1/responses"`
  - Codex subscription default (ChatGPT backend): `"/responses"` (base_url already includes `/backend-api/codex`)
- `headers` (hash; default `{}`)
- `requires_credential` (boolean)
- `credential_type` (string, optional; default `api_key` when `requires_credential: true`)
- `wire_api` (enum): `responses|chat_completions`
- `transport` (enum):
  - when `wire_api: responses`: `http_sse|websocket|auto`
  - when `wire_api: chat_completions`: `http`
- `default_model` (string) — a `model_key` under this provider
- `models` (hash) — at least 1 enabled model
- `environments` (array of strings, optional): restrict catalog visibility/usage to specific Rails envs (e.g. `[development, test]`). If omitted, allowed in all envs.

#### Required fields (model)
Each model must define:
- `display_name` (string)
- `api_model` (string)
- `capabilities` (hash)
  - `capabilities.input.text` (boolean; default true)
  - `capabilities.input.image` (boolean; default false)
  - `capabilities.tools.tool_calling` (boolean; default false)
  - `capabilities.protocol` (enum): `responses|chat_completions` (should match provider defaults unless intentionally overridden)
- `context_window_tokens` (integer; required; used for budgeting)
- `tokenizer_hint` (string, optional; default derived from `api_model` via `Cybros::TokenEstimation.canonical_model_hint`)
- `request_defaults` (hash, optional)
  - `reasoning_effort` (enum; optional): `none|minimal|low|medium|high|x_high` (names should match our eventual provider mapping)

#### Transport selection semantics (responses)
- `transport: http_sse`: always use SSE streaming for responses.
- `transport: websocket`: always attempt WS for responses; if WS support is not present in the runtime (library missing/unimplemented), **hard error** (misconfiguration).
- `transport: auto`: prefer WS when available; otherwise use SSE. When falling back, set a metadata flag (e.g. `llm.transport_used: "http_sse"`) so it is not “silent”.

#### Boot-time validation behavior (hard fail)
On app boot (or first use if lazy-loaded), validate and raise an error with:
- File path(s) used (default + override)
- A compact list of validation errors with JSON-pointer-like paths, e.g.:
  - `providers.openai.models.gpt-5.2.context_window_tokens must be an Integer`
  - `providers.openai.default_model references missing model_key: gpt-5.2`
  - `providers.codex_subscription.wire_api must be 'responses' (got 'chat_completions')`

#### Missing credential behavior
- If `requires_credential: true` and the DB has no usable credential for that `provider_key`, the provider’s models are hidden from the composer picker (and any turn that tries to use them hard-errors).
- If `requires_credential: false`, the provider may be used without a DB credential row (still allow creating one for usage/reporting if desired).

#### Provider failure behavior (hard error, no fallback)
- **All provider call failures are surfaced to the user as hard errors** (and the turn is rejected), including:
  - invalid/unauthorized credentials (401/403)
  - model not found (404 / provider-specific error codes)
  - network failures / timeouts / upstream 5xx
- We still keep internal retries where safe (idempotent reconnects for streaming), but we do not “fail over to another model/provider” implicitly.

### DB: `llm_providers` (repurposed to “credential + usage anchor”, associated by key)
Keep a DB record per `provider_key` for encrypted secrets + usage attribution:
- `provider_key` (string, unique) — matches YAML provider key
- `credential_type` (string) — `api_key|oauth_codex`
- encrypted fields:
  - `api_key` (existing)
  - `access_token`, `refresh_token`, `expires_at`, `account_id` (new, for Codex subscription)
No operational overrides for base_url/models in DB; YAML remains the source of truth (DB is orthogonal: secrets + usage attribution only).

### Turn-level selection persistence
Store “chosen model” for a user turn in conversation graph metadata as:
- `provider_key`
- `model_key`
- `model_ref` (derived, stored for convenience)

If the catalog changes and the stored model_ref no longer exists or is disabled, **hard error** and require re-selection.

---

## Provider architecture (C “ProviderAdapter”)

### New interface (Ruby)
Introduce an adapter abstraction in app domain (Cybros), not AgentCore:

- `LLM::ProviderAdapter`
  - `#list_models(endpoint:) -> Array<ModelSpec>` (optional, depending on sync mode)
  - `#build_agent_core_provider(endpoint:, model:) -> AgentCore::Resources::Provider::Base`
  - `#token_counter_for(model:) -> AgentCore::Resources::TokenCounter::Base` (returns estimator configured with tokenizer hint + overhead)
  - `#supports_tools?(model:)`, `#supports_images?(model:)` helpers (derived from capabilities)

**Key:** AgentCore runtime still speaks in terms of “provider + model string”. We will hand AgentCore a provider object whose internal client points at the right wire API and transport.

### SimpleInference protocol expansion (reusable across projects)
Add:

- `SimpleInference::Protocols::OpenAIResponses`
  - `POST /v1/responses`
  - streaming:
    - SSE: `text/event-stream` parse (`response.output_text.delta`, `response.output_item.done`, `response.completed`, etc.)
    - WebSocket: connect to `ws(s)://.../v1/responses`, send request JSON frames, receive event frames (based on Codex reference patterns)

This becomes the foundation for:
- OpenAI Responses (API key)
- Codex subscription (ChatGPT backend base_url)
- Potential future providers that speak Responses semantics

### Adapters to ship (first two milestones)

#### `codex_subscription` adapter
- Uses `OpenAIResponses` protocol.
- Auth: `LLMCredential(type=oauth_codex)` injects `Authorization: Bearer` and optional `ChatGPT-Account-Id`.
- Base URL default: `https://chatgpt.com/backend-api/codex`
- Wire API: `responses`
- Transport: `websocket` (per your selection)
- Model catalog: defined in YAML (Codex-only models + any reasoning-effort variants). No DB model sync in Phase 1.

#### `openrouter` adapter
- Likely uses existing `OpenAICompatible` *or* `OpenAIResponses` depending on how we choose to standardize. (Codex and modern OpenAI are trending toward Responses; OpenRouter historically is chat-completions heavy but also supports responses for some models; implement after Phase 1.)
- Auth: `api_key`
- Headers: optional referer/title
- Model catalog: defined in YAML. Optionally add a “diagnostic fetch models” tool later, but do not depend on `/v1/models` correctness for normal operation.

---

## Capability gating & request shaping

### Tools
Before building a prompt with tools, gate on:
- `ModelSpec.capabilities.tools.tool_calling == true` (from effective YAML catalog)

If false:
- **Hard error**: reject sending the turn and surface a UI error: “Selected model does not support tool calling.”

### Images
Before serializing `ImageContent` into OpenAI-format content blocks:
- require `ModelSpec.capabilities.input.image == true` (from effective YAML catalog)

If false:
- **Hard error**: reject sending the turn and surface a UI error: “Selected model does not support image input.”

### Protocol selection
Treat protocol as a property of the selected model (with endpoint default):
- If model protocol is `responses`, route through `OpenAIResponses`.
- If `chat_completions`, route through existing `OpenAICompatible`.

---

## Token estimation plan

### What we will do
- Use `Cybros::TokenEstimation.canonical_model_hint(api_model)` to compute a default `tokenizer_hint` when the YAML entry omits it.
- Prefer `tokenizer_hint` from the YAML `ModelSpec` when present.
- Runtime token_counter for a turn should be:
  - `AgentCore::Resources::TokenCounter::Estimator.new(token_estimator: Cybros::TokenEstimation.estimator(...), model_hint: tokenizer_hint, per_message_overhead: <from model/heuristic>)`

### Why
- OpenRouter models vary (HF tokenizers vs tiktoken models), and we need budgeting accuracy.
- This matches VibeTavern’s strategy and reuses existing Cybros registry implementation.

---

## UI changes

### Chat composer: model selection
- Add a model dropdown in the chat composer (common agent products pattern).
- The dropdown lists “enabled” models from the **effective YAML catalog**.
- To avoid provider/model name collisions, store selection as `provider_key` + `model_key` (and derived `model_ref`).
- The chosen model is stored in turn metadata and used by `AgentRuntimeResolver` for that turn.

### Admin/settings: provider credentials (DB) + catalog visibility (YAML)
Keep existing `system/settings/llm_providers` entrypoint but evolve it into:
- Provider credentials list/edit keyed by `provider_key`
  - show effective provider config (read-only): enabled/base_url/wire_api/transport/default_model/requires_credential
  - edit only DB-backed credential fields (API key / OAuth tokens) and enable/disable override if we decide to support it
- Catalog view (read-only):
  - list effective models per provider (from YAML) with their capabilities and reasoning-effort variants
  - no per-model overrides in Phase 1/2 (changes happen via YAML override injection)

Reasoning effort:
- Stored in YAML as `request_defaults.reasoning_effort`.
- There is **no separate “reasoning effort” control in the composer**.
- If you want users to choose between efforts, define distinct model variants (distinct `model_key`s). Those variants appear as separate choices in the model picker.

---

## Usage statistics (tokens)

### What we already have
This repo already has graph/lane-scoped aggregation utilities:
- `DAG::Lane#llm_usage_stats(...)`
- `DAG::Graph#llm_usage_stats(...)`

They aggregate from terminal `dag_nodes.metadata["usage"]` and group by `dag_node_bodies.output["provider"]` and `["model"]`.

### What we will add
Add system-scoped usage stats for:
- **Per-user, by model_ref** (and by provider_key).
- **Global totals by provider_key** (all users).

### Canonical dimensions (must be stable)
To avoid collisions (same upstream model name across providers), we treat:
- `provider_key` as the canonical provider dimension.
- `model_ref = "#{provider_key}/#{model_key}"` as the canonical model dimension.

Therefore, when producing the `agent_message` node output payload, we must write:
- `body_output["provider"] = provider_key`
- `body_output["model"] = model_ref`
- (optional) also include `body_output["api_model"] = api_model` for debug/audit.

### Proposed API surface
- `User#llm_usage_stats(...)` (or a service `LLM::UsageStats.call(user: ...)`) returning the same shape as `DAG::UsageStats`:
  - `totals`
  - `by_model` (grouped by provider_key + model_ref)
  - `by_day`
- `LLM::UsageStats.global_by_provider(...)` for global provider totals.

### Implementation notes
- Prefer querying off `dag_nodes` + joins rather than introducing a second usage-events table:
  - join `dag_nodes -> dag_graphs (attachable) -> conversations -> users`
  - filter to terminal nodes with `metadata ? 'usage'`
  - group by provider/model fields in `dag_node_bodies.output`
- Add any missing indexes only if needed after measuring (Phase 0 is small).

## Milestones / Phasing

### Phase 1: Provider refactor + Codex subscription
Deliverables:
- YAML config loader + schema validation + layering (default + override)
- DB schema changes for credentials keyed by `provider_key` (and OAuth fields for Codex)
- ProviderAdapter architecture + wiring in `AgentRuntimeResolver`
- `SimpleInference::Protocols::OpenAIResponses` (SSE + WebSocket)
- Codex subscription adapter + OAuth credential storage/refresh
- Chat composer model picker (backed by YAML catalog)

### Phase 2: OpenRouter
Deliverables:
- OpenRouter endpoint template + adapter
- YAML catalog entries for OpenRouter models (capabilities defaults + reasoning variants)
- Regression tests ensuring non-tools/image models behave correctly

---

## Testing plan (must-have coverage)

### Unit tests (Ruby)
- `SimpleInference::Protocols::OpenAIResponses`
  - SSE parsing of:
    - `response.output_text.delta`
    - `response.output_item.done` for message + function_call
    - `response.completed` usage extraction
  - WebSocket transport:
    - connect + send request + receive events (use a local mock WS server patterned after `references/codex/scripts/mock_responses_websocket_server.py`)
- `ProviderAdapter` / endpoint wiring:
  - model capability gating: tools/images/protocol mismatch rejects the turn before any provider request is sent
  - token counter uses `Cybros::TokenEstimation` registry estimator with canonical hint
- Credential refresh:
  - oauth token refresh when `expires_at < now`
  - inject `ChatGPT-Account-Id` when present

### Integration tests (Rails)
- Settings UI:
  - create/update provider credential keyed by `provider_key`
  - render effective YAML provider config (read-only) alongside credential editor
- Conversation turn selection:
  - choosing a model in composer persists to turn metadata
  - runtime uses that model; if incompatible (tools/images/protocol), sending is rejected with a clear error

- Usage stats:
  - user usage stats aggregates across conversations and groups by `model_ref`
  - global provider totals aggregate across users (even if only 1 user exists today)

### E2E (Playwright) — optional but recommended
- “Select model in composer” smoke
- “Send message; see streaming; tool call works” smoke

### Manual test checklist (high-signal)
- Codex subscription:
  - login (oauth) works; token refresh works after expiry simulation
  - responses stream arrives; tool calling works
- OpenRouter:
  - a tools-capable model can call tools
  - selecting a non-tools model and attempting tool use fails fast with a clear error
  - selecting a no-image model and attempting image input fails fast with a clear error

---

## Potential blockers / discussion points (identify early)

### WebSocket client implementation in Ruby
Responses-over-WebSocket requires an outbound WS client that:
- supports custom headers (Authorization, ChatGPT-Account-Id, beta headers)
- supports clean close + idle timeout
- does not require a global event loop that conflicts with Rails (avoid hard dependency on EventMachine)

Plan: pick one WS client library early and build the protocol around it, but **ship in two steps**:
- **Step 1**: `OpenAIResponses` SSE path is the “known good” baseline that must work.
- **Step 2**: WS transport is implemented and can be enabled via config (`transport: websocket` or `transport: auto`). If `auto` is chosen, it may fall back to SSE with an explicit metadata marker (not silent).

### Codex subscription OAuth UX in a web app
OpenCode’s CLI uses a local callback server and/or device flow. In Rails we should prefer a web-friendly flow:
- **Device flow (recommended)**: show a code + link to authorize; poll token endpoint; store refresh/access/expires/account_id.
- Ensure we can refresh tokens server-side and handle region/account headers (`ChatGPT-Account-Id`).

### “Model catalog drift” vs existing conversation turns
With YAML as source-of-truth, stored `model_ref` can become invalid after config changes. Policy is “hard error and require re-selection”, but we should:
- ensure the UI error is actionable (show previous selection + suggest alternatives)
- avoid breaking background jobs or retries silently

### Capability truthfulness (especially OpenRouter)
OpenRouter capabilities are not reliable unless explicitly curated. Our default stance should be conservative:
- default `tool_calling: false`, `image: false` unless explicitly enabled in YAML.

## Implementation checklist (task breakdown)

### Task group A: YAML catalog + DB credential anchor
- [ ] Add default YAML catalog file (e.g. `config/llm/providers.yml`) with:
  - providers (`provider_key`) + base_url/headers/enabled/default_model/requires_credential/wire_api/transport
  - models (`model_key`) with capabilities/tokenizer_hint/context window and reasoning-effort variants
- [ ] Add YAML loader + deep-merge layering (default + optional override via `CYBROS_LLM_CONFIG_PATH`)
- [ ] Add schema validation + helpful error reporting on boot (fail-fast with actionable message)
- [ ] Update DB `llm_providers` to include `provider_key` (unique) and credential_type fields; keep API key encrypted
- [ ] Add encrypted OAuth credential fields for Codex subscription (`access_token`, `refresh_token`, `expires_at`, `account_id`)
- [ ] Data migration: map existing `llm_providers` rows to `provider_key` (one-time; choose a stable default key like `openai_compatible_1` if needed)

### Task group B: `simple_inference` protocol layer
- [ ] Add `SimpleInference::Protocols::OpenAIResponses` non-streaming `POST /responses`
- [ ] Add SSE streaming for responses
- [ ] Add WS streaming for responses
- [ ] Add fixtures + tests for event parsing and usage extraction

### Task group C: ProviderAdapter + runtime wiring
- [ ] Implement adapter registry keyed by `adapter_key`
- [ ] Update `Cybros::AgentRuntimeResolver` to:
  - resolve a `ModelSpec` from the effective YAML catalog (by `provider_key/model_key`)
  - build provider via adapter
  - install token_counter via adapter (Cybros token estimation)
- [ ] Add capability gating for tools/images/protocol at prompt-build time (hard error, no fallback)

### Task group D: Codex subscription
- [ ] Credential type `oauth_codex` + refresh service (auth.openai.com token refresh)
- [ ] Codex endpoint template (`https://chatgpt.com/backend-api/codex`)
- [ ] Codex models catalog entries in YAML (Codex-only) + optional reasoning-effort variants
- [ ] End-to-end “send a turn” using Responses over WebSocket (mock server in tests)

### Task group E: UI — model selection + credential editing
- [ ] Chat composer model dropdown (enabled models from YAML catalog)
- [ ] Persist selected model into the next turn metadata
- [ ] Settings UI: provider credential edit page keyed by `provider_key` with read-only effective config display
- [ ] Reasoning effort stored in YAML as a per-model default; no composer picker

### Task group F: Phase 2 — OpenRouter
- [ ] OpenRouter endpoint template + adapter
- [ ] OpenRouter models catalog entries in YAML (capabilities defaults + reasoning-effort variants where applicable)
- [ ] Provide a safe default for unknown capabilities (deny tools/images unless explicitly enabled)
- [ ] Add regression tests for “non-tools model” and “no-image model”

### Task group G: Dev/Test-only local inference provider
- [ ] Add a `local` provider entry to the default YAML catalog with `environments: [development, test]`
- [ ] Choose one:
  - `ollama` (OpenAI-compatible HTTP) for local dev, or
  - a “mock provider” base_url for tests
- [ ] Ensure this provider is not visible/usable in production env even if accidentally configured

### Task group H: Usage statistics (per user + global)
- [ ] Ensure agent message output payload includes canonical `provider_key` + `model_ref` for aggregation
- [ ] Add a `LLM::UsageStats` service (or `User#llm_usage_stats`) that aggregates usage across graphs by joining to conversations/users
- [ ] Add a global “by provider” aggregation across all users
- [ ] Add tests:
  - per-user by-model stats
  - global by-provider stats

---

## Open questions (to resolve during implementation)
### Decisions locked in (2026-03-06)
- **Protocol support in AgentCore provider interface**: extend `AgentCore::Resources::Provider::SimpleInferenceProvider` to support both `chat_completions` and `responses` shapes (by delegating to `SimpleInference::Protocols::OpenAICompatible` and `SimpleInference::Protocols::OpenAIResponses` respectively).
- **Capability mismatch behavior (tools/images/protocol)**: **hard error**; reject sending the turn (no automatic fallback). Surface a clear UI error pointing to the selected model and the missing capability, and suggest selecting a compatible model.
- **Transport rollout**: ship SSE first as baseline; WS is supported by the protocol but may be enabled incrementally. Any fallback between transports must be explicit via `transport: auto` and recorded in metadata (not silent).
- **Codex OAuth flow in UI**: implement device flow (code + authorize link + polling) as the primary web UX.
- **Provider failures**: hard error (no model/provider failover) for auth/model/network failures; require user correction.

### Remaining open questions
- Whether to allow a per-conversation or per-profile “auto fallback” policy later (out of scope for Phase 1/2).

