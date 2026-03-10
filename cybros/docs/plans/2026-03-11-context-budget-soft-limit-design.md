# Context Budget Soft Limit Design

## Status

Approved design notes for model/provider context-window policy and agent-visible compaction behavior.

## Decisions

### 1. Hard window is two-layered

- `provider.context_window_tokens` is optional and represents the inference-server hard cap.
- `provider.context_window_tokens = nil` or `0` means "unlimited at provider layer".
- `model.context_window_tokens` remains required and represents the model-declared hard cap.
- The runtime uses:
  - `effective_context_window_tokens = min(model.context_window_tokens, provider.context_window_tokens)` ignoring provider `nil/0`
  - `effective_prompt_budget_tokens = max(effective_context_window_tokens - reserved_output_tokens, 0)`

### 2. Soft limit is model-scoped and advisory

- Model config adds:
  - `context_soft_limit_tokens`
  - `context_soft_limit_ratio`
- Either field may be omitted.
- If both are present, the stricter value wins.
- Ratio is applied against `effective_prompt_budget_tokens`, not raw model context.
- Final value is clamped to `effective_prompt_budget_tokens`.

### 3. Agent sees budget pressure and chooses compaction

- Cybros remains the owner of the agent loop and prompt assembly.
- When prompt estimate reaches the effective soft limit, Cybros injects budget guidance into the prompt.
- When the prompt only fits after platform pruning/shrinking, Cybros marks that state as forced pressure and instructs the agent to compact before continuing.
- The agent should respond to pressure by calling `compact_context`, not by silently relying on repeated platform trimming.

### 4. `compact_context` becomes a first-class native tool

- `compact_context` should be exposed as a native tool so an agent tool call expands into a normal DAG task.
- This preserves the desired audit shape:
  - `agent_message -> task(compact_context) -> next agent_message`
- The tool should reuse the existing conversation compaction planning path and continue to route through `runtime_surface.compact_context`.
- Existing system-authored finished `compact_context` preflight tasks remain historical artifacts and do not block introducing the tool.

### 5. Loop suppression is required

- Prompt guidance must not repeatedly tell the agent to compact for the same unchanged budget state.
- A turn-scoped `budget_fingerprint` should suppress repeated compaction advice when:
  - a matching `compact_context` already succeeded
  - or a matching `compact_context` returned noop
- If context changes materially, a new fingerprint may re-enable compaction advice.
- Existing `max_steps_per_turn` remains the outer safety belt.

### 6. Observability stays in existing budget/task channels

- Extend `context_cost` with effective hard/soft limit facts and budget state instead of creating a parallel telemetry schema.
- `compact_context` task metadata should record:
  - trigger reason
  - budget fingerprint
  - estimated tokens before/after
  - target limit
  - compacted turn ids
  - noop flag
- `compact_context` remains classified as a preflight task in projections/stats.

## Explicit V1 Boundary

V1 covers:

- provider-level optional hard cap
- model-level soft limit config
- prompt-visible budget guidance
- agent-initiated `compact_context` task insertion
- loop suppression and audit metadata

V1 does not yet cover:

- automatic platform insertion of a `compact_context` task when prompt assembly cannot fit at all before any LLM call

That harder overflow recovery path is a separate executor/error-flow change and should be treated as follow-up work.
