# Context Budget Soft Limit Design

## Status

Approved design notes for model/provider context-window policy and agent-visible compaction behavior.

## Decisions

### 0. This is a destructive replacement, not a compatibility rollout

- This work replaces the current compact-related main path rather than layering on top of it.
- The standing product agreement applies:
  - breaking changes are acceptable
  - compatibility shims are not required
  - database reset is allowed if that simplifies the cut
- Prefer deleting superseded compact behavior over preserving dual paths.
- In particular, V1 should remove or retire the current main-path uses of:
  - app-side multi-message overflow compaction at conversation entry
  - `input_policy.oversize.multi_message.strategy` as the driver for conversation compaction
  - `auto_compact` as the primary long-conversation compaction story
  - `compact_context` projection as `preflight_task` for the active path
- Superseded concept names should remain only in explicitly archived docs under `docs/archive`, or in historical rows that are irrelevant because the environment allows reset.

### 1. Hard window is two-layered

- `provider.context_window_tokens` is optional and represents the inference-server hard cap.
- `provider.context_window_tokens = nil` or `0` means "unlimited at provider layer".
- `model.context_window_tokens` remains required and represents the model-declared hard cap.
- `AgentCore::DAG::Runtime.context_window_tokens` remains the canonical effective hard cap consumed by budget enforcement.
- The resolver computes:
  - `effective_context_window_tokens = min(model.context_window_tokens, provider.context_window_tokens)` ignoring provider `nil/0`
  - `effective_prompt_budget_tokens = max(effective_context_window_tokens - reserved_output_tokens, 0)`
- Additional runtime fields such as `model_context_window_tokens` and `provider_context_window_tokens` are additive observability inputs, not a second hard-cap authority.

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
- The bundled/default agent context manager should assemble prompt-side summaries, notes, and similar working material from `lane.prompt_buffer` before budget evaluation runs.
- When prompt estimate reaches the effective soft limit, Cybros injects budget guidance into the prompt.
- When the prompt only fits after platform pruning/shrinking, Cybros marks that state as forced pressure and instructs the agent to compact before continuing.
- The agent should respond to pressure by calling `compact_context`, not by silently relying on repeated platform trimming.

### 4. Budget-state detection borrows Codex-style trigger points, but durable actions still land on the DAG

- Borrow the useful extension points from Codex-style compaction control:
  - model-level compaction threshold
  - compact-specific prompt/config
  - pre-sampling trigger
  - post-sampling trigger
  - loop guard against repeated compaction attempts
- Do not copy the "silent off-graph system compaction" semantics.
- In Cybros, budget-state detection remains code-driven, but any durable result of budget handling must still materialize as DAG activity.
- The key split is:
  - Cybros kernel/controller computes budget facts and budget state
  - agent program decides what action to take in response
  - execution layer materializes that outcome as prompt guidance or a normal `compact_context` task

### 5. Agent-program policy output is explicit: `none`, `advise_compact`, or `enqueue_compact`

- `none`
  - no budget action is needed
- `advise_compact`
  - inject budget guidance into the prompt and let the model choose whether to call `compact_context`
- `enqueue_compact`
  - agent-program logic immediately inserts a `compact_context` task into the current turn before continuing the loop
- Cybros itself only needs to expose enough budget state and execution primitives for an agent program to make this choice.
- This keeps the decision logic deterministic while preserving DAG-first execution semantics.

### 5.1. The bundled default policy is a helper, not a kernel invariant

- The bundled default mapping from `budget_state` to `budget_action` should live in a distinct Cybros-owned helper/policy object.
- `AgentMessageExecutor` and related DAG executors should consume the policy output, not own the raw decision table.
- This preserves the agreed split:
  - kernel/runtime owns budget facts, prompt assembly, tool registry, policy/approval, and DAG materialization
  - bundled agent-program policy owns the default choice of `none | advise_compact | enqueue_compact`
- This boundary keeps the design orthogonal to future alternative agent programs.

### 6. Cybros owns the canonical tool registry; the agent program applies visibility masks

- Cybros should continue to register the full canonical native-tool surface.
- The agent program/controller decides which subset is model-visible for a given step.
- `compact_context` should therefore be:
  - present in the canonical registry
  - hidden from the model by default
  - unmasked when policy output is `advise_compact`
  - unnecessary to expose when policy output is `enqueue_compact`, because the controller has already decided to insert the task
- This keeps tool semantics uniform across ordinary tools, subagent tools, and budget-management tools while preserving per-step control.

### 7. `compact_context` becomes a first-class native tool

- `compact_context` should be exposed as a native tool so an agent tool call expands into a normal DAG task.
- This preserves the desired audit shape:
  - `agent_message -> task(compact_context) -> next agent_message`
- The tool should reuse the existing conversation compaction planning path and continue to route through `runtime_surface.compact_context`.
- Agent-triggered `compact_context` should be treated as a normal turn-internal task, not as a privileged preflight path.
- Existing system-authored finished `compact_context` preflight tasks remain historical artifacts and do not block introducing the tool.

### 8. Agent programs may keep the default helper or bring their own compaction logic

- The bundled `compact_context` tool is valuable as a default, general-purpose helper.
- But agent programs should not be forced to use Cybros's bundled compaction prompt/strategy.
- An agent program may choose to:
  - call the bundled `compact_context`
  - generate its own compaction summary or plan
  - use its own prompt, subagent, or multi-step workflow before applying compaction
- The boundary is:
  - Cybros owns the loop, DAG materialization, and privileged context-visibility mutation
  - agent programs own whether to compact and how to derive the compacted representation
- A future extension may allow agent programs to contribute additional tool definitions/implementations through a Cybros-owned public tool-extension surface.
- Even in that future model, tool execution still belongs to Cybros:
  - Cybros merges the visible tool set
  - Cybros applies policy/approval/audit
  - Cybros dispatches execution through approved adapters
- This keeps Cybros generic while still allowing opinionated default behavior.

### 9. Agent-authored work must materialize on the DAG

- Cybros owns the agent loop.
- Any agent-authored action, decision, or durable work that enters the loop must materialize as DAG node(s).
- No off-graph agent work may mutate conversation execution state.
- Budget pressure itself may remain prompt-only guidance, but once the agent chooses to act on it, that action must appear as normal DAG activity.
- This rule applies to `compact_context` and should also guide future work such as retries, replans, approval requests, and subagent activity.
- This is a product-shape target; if it blocks requirement delivery in practice, revisit explicitly rather than silently bypassing it.

### 10. Follow-up work should use a public execution abstraction, not raw DAG mutation

- The agent should not receive direct DAG mutation authority.
- Instead, Cybros should expose a bounded public execution abstraction for "what work happens next".
- Existing tool calling already provides the right shape for this abstraction:
  - visible native tools
  - policy/approval mediation
  - normal task materialization on the DAG
  - replayable audit semantics
- For V1, `compact_context` should enter that abstraction as a native tool alongside ordinary tools and subagent tools rather than introducing a second special mechanism.
- Longer term, if Cybros needs follow-up actions that are not naturally tool-shaped, they should still enter through a Cybros-owned declarative execution surface rather than raw node/edge mutation.

### 11. Codex-like extension points map cleanly to Cybros controller stages

- `before_prompt`
  - compute effective hard/soft limits
  - estimate prompt size
  - compute budget state and expose budget facts
- `prepare_turn`
  - still allowed to reshape prompt view after it fits
  - not allowed to perform silent durable compaction
- `after_model_step`
  - evaluate whether the loop is about to continue with already-dangerous token state
  - may escalate budget state for the next agent-program decision
- `after_task_result`
  - update budget state after tool/subagent output expansion
  - suppress repeat compaction via `budget_fingerprint`

### 12. Budget guidance payload should stay minimal

- When policy output is `advise_compact`, the prompt should receive only the minimum structured budget facts needed for the model to make a good decision.
- V1 guidance payload should contain:
  - `effective_prompt_budget_tokens`
  - `effective_context_soft_limit_tokens`
  - `estimated_tokens`
  - `budget_state`
  - `compact_context_available`
- Do not expose extra controller internals such as:
  - `budget_fingerprint`
  - raw provider/model config details beyond the effective limits already computed
  - compaction-attempt history unless a later phase proves the model needs it
- `compact_context_available` reflects the current visibility mask rather than canonical registry membership.
- `compact_context_available` is therefore a post-masking field: budget facts may exist before it does, but the final prompt guidance should only populate it after tool visibility has been resolved for that step.

### 13. `near_hard_cap` is an agent-program constant, not a product config

- V1 should not add another user-facing context config field.
- Instead, the agent program keeps an internal escalation constant such as:
  - `NEAR_HARD_CAP_RATIO = 0.9`
- The controller computes:
  - `near_hard_cap` when `estimated_tokens >= floor(effective_prompt_budget_tokens * NEAR_HARD_CAP_RATIO)`
- This constant belongs to agent-program logic, not Cybros product configuration.
- Different agent programs may eventually choose different internal constants without requiring Cybros catalog/schema changes.

### 14. Default bundled agent-program strategy matrix

- `normal`
  - condition: `estimated_tokens < effective_context_soft_limit_tokens`
  - action: `none`
- `soft_limit_reached`
  - condition: prompt fits cleanly but estimate has crossed the soft limit
  - action: default `advise_compact`
  - rationale: preserve agent autonomy because this is a soft limit
- `near_hard_cap`
  - condition: prompt still fits cleanly, but estimate has crossed the agent-program internal escalation threshold
  - action: default `enqueue_compact`
  - rationale: by this point remaining headroom is too small to rely on another round-trip safely
- `forced_fit`
  - condition: prompt only fits after drop memory / prune tool outputs / shrink turns
  - action: default `enqueue_compact`
  - rationale: by the time platform had to trim to fit, continuing without durable compaction is usually unstable
- `hard_overflow_pre_prompt`
  - condition: prompt still cannot fit before any provider call
  - action: leave as follow-up unless implementation ends up straightforward enough to include during delivery
  - rationale: this is the most invasive recovery path because it changes pre-execution control flow
- This matrix describes the default bundled agent-program behavior, not a mandatory Cybros kernel rule.

### 15. Loop suppression is required

- Prompt guidance must not repeatedly tell the agent to compact for the same unchanged budget state.
- A turn-scoped `budget_fingerprint` should suppress repeated compaction advice when:
  - a matching `compact_context` already succeeded
  - or a matching `compact_context` returned noop
- If context changes materially, a new fingerprint may re-enable compaction advice.
- Existing `max_steps_per_turn` remains the outer safety belt.

### 16. Observability stays in existing budget/task channels

- Extend `context_cost` with effective hard/soft limit facts and budget state instead of creating a parallel telemetry schema.
- Persist the controller decision for each turn step:
  - `budget_action = none | advise_compact | enqueue_compact`
  - `budget_state = normal | soft_limit_reached | near_hard_cap | forced_fit`
- `compact_context` task metadata should record:
  - trigger reason
  - budget fingerprint
  - estimated tokens before/after
  - target limit
  - compacted turn ids
  - noop flag
- `source = context_budget_policy | model_choice | manual`
- Agent-triggered `compact_context` should project as ordinary turn task activity with explicit source/reason metadata rather than relying on preflight-only semantics.

### 17. Validation requires integration coverage, not only unit tests

- This design should be validated primarily through scenario/integration tests that exercise the real agent loop shape.
- Required coverage areas:
  - Cybros exposes budget state and minimal guidance without forcing a specific compaction strategy
  - soft limit reached -> budget guidance visible -> agent chooses `compact_context` -> normal task node materializes -> next agent step continues
  - budget guidance payload contains only the approved minimal fields
  - near-hard-cap state -> controller enqueues `compact_context` before the next risky model step
  - forced-fit state -> controller enqueues `compact_context` -> normal task node materializes -> next agent step continues
  - repeated unchanged budget state -> `budget_fingerprint` suppresses repeated compaction nudges
  - `compact_context` + subagent/tool-heavy turns continue to project cleanly in turn execution views
  - approval/policy mediation still works if `compact_context` or follow-up tools later gain restricted modes
- E2E coverage should confirm that transcript/activity surfaces show this as ordinary turn activity rather than invisible system work.

### 18. Active documentation must converge on one budget/compaction story

- The shipped implementation must update active docs so they no longer describe `auto_compact` as the primary path for long conversations.
- Required active-doc touch points:
  - `docs/agent_core/public_api.md`
  - `docs/agent_core/behavior_spec.md`
  - `docs/agent_core/context_management.md`
  - `docs/agent_core/node_payloads.md`
  - `docs/agent_core/knowledge_context_memory_design.md`
  - `docs/agent_core/knowledge_context_memory_implementation_plan.md`
- If any of those docs still need the old vocabulary for historical context, move them under `docs/archive` instead of leaving the legacy story in active docs.

## Explicit V1 Boundary

V1 covers:

- provider-level optional hard cap
- model-level soft limit config
- Codex-like policy trigger points (`before_prompt`, `after_model_step`)
- agent-program internal `near_hard_cap` escalation constant
- prompt-visible budget guidance for `advise_compact`
- bundled agent-program `enqueue_compact` behavior for `near_hard_cap` and `forced_fit`
- `compact_context` task insertion as ordinary turn activity
- loop suppression and audit metadata

V1 does not yet cover:

- automatic recovery for `hard_overflow_pre_prompt` when prompt assembly cannot fit at all before any LLM call
- a new public API for agent-program-contributed tool implementations, MCP adapters, or skills overlays inside the canonical loop

That harder overflow recovery path is a separate executor/error-flow change and should be treated as follow-up work.
