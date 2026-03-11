# Context Budget Soft Limit Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the old app-side multi-message overflow compaction path with a DAG-first context-budget system that computes provider/model hard limits, surfaces soft-pressure to the agent, migrates default agent context management onto `lane.prompt_buffer`, and materializes bundled `compact_context` actions as ordinary turn tasks.

**Architecture:** Keep Cybros kernel responsible for budget-state detection, prompt assembly, canonical tool registration, policy/approval, and DAG materialization. `runtime.context_window_tokens` remains the single effective hard cap consumed by AgentCore, while raw model/provider caps travel alongside it for observability. The bundled/default agent context manager should render prompt-side summaries/notes from `lane.prompt_buffer` before budget evaluation. Move multi-message compaction decisions into the agent loop: `ContextBudgetManager` computes budget state and emits minimal guidance, a bundled default budget-policy helper maps that state to `none|advise_compact|enqueue_compact`, and all durable compaction work lands on the DAG as ordinary task activity.

**Tech Stack:** Ruby 4.0.1, Rails 8.2 alpha, PostgreSQL DAG models, AgentCore runtime/tool loop, Minitest scenario/integration tests

---

## Destructive-Cut Assumptions

- This plan is intentionally destructive.
- Do not preserve compatibility aliases, dual paths, or backfill-only scaffolding unless a test proves it is still required inside the same batch.
- `db:reset` remains an acceptable way to land the cut.
- The implementation should delete or retire superseded compact behavior, not merely de-prioritize it.
- Superseded concept names should remain only in explicitly archived docs under `docs/archive`.
- Cleanup targets for this batch:
  - app-side multi-message overflow compaction at conversation entry
  - `input_policy.oversize.multi_message.strategy` as a live compaction control
  - active-path `compact_context` classification as `preflight_task`
  - old active-doc guidance that still presents `auto_compact` as the primary story


### Task 1: Extend Catalog And Runtime Budget Contract

**Files:**
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/config/llm/providers.yml`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/llm/catalog.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/runtime.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/cybros/llm/catalog_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/cybros/agent_runtime_resolver_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb`

**Step 1: Write the failing catalog tests**

Add tests that prove:
- `provider.context_window_tokens` is optional
- `provider.context_window_tokens: 0` is accepted and means “unlimited”
- `model.context_soft_limit_tokens` accepts a positive integer
- `model.context_soft_limit_ratio` accepts a numeric ratio in `(0, 1]`
- invalid provider/model values fail with stable validation pointers

**Step 2: Run the catalog tests to verify they fail**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/lib/cybros/llm/catalog_test.rb
```

Expected: FAIL on unknown fields or missing validation rules.

**Step 3: Implement catalog parsing and runtime propagation**

Update:
- `Catalog.validate!` to allow/validate provider hard-cap and model soft-limit fields
- `providers.yml` sample data to include at least one provider-level hard cap example and one model soft-limit example
- `AgentRuntimeResolver.build_llm_selection` / runtime kwargs to propagate:
  - effective `context_window_tokens`
  - `model_context_window_tokens`
  - `provider_context_window_tokens`
  - `context_soft_limit_tokens`
  - `context_soft_limit_ratio`
- `AgentCore::DAG::Runtime` to carry the new raw budget inputs while keeping `context_window_tokens` as the canonical effective hard cap

Do not compute final budget state in the catalog/resolver layer; only normalize the raw inputs and compute the effective runtime hard cap.

**Step 4: Add/adjust runtime resolver tests**

Cover:
- `runtime.context_window_tokens` remains the effective hard cap exposed to the budget layer
- provider hard cap reduces that effective hard cap when stricter than the model value
- `0` or missing provider cap does not constrain model hard cap
- raw model/provider caps survive resolver normalization for observability
- soft-limit config survives resolver normalization

**Step 5: Run the targeted tests**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/lib/cybros/llm/catalog_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb
```

Expected: PASS.

**Step 6: Commit**

```bash
git add config/llm/providers.yml lib/cybros/llm/catalog.rb lib/cybros/agent_runtime_resolver.rb lib/agent_core/dag/runtime.rb test/lib/cybros/llm/catalog_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb
git commit -m "feat: add context budget config fields"
```

### Task 2: Teach ContextBudgetManager To Compute Budget Facts And States

**Files:**
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/context_budget_manager.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/runtime_surface/inputs.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/agent_core_context_cost_report_test.rb`

**Step 1: Write failing budget-manager tests**

Add tests for:
- effective hard cap = min(model, provider) ignoring provider `nil/0`
- effective soft limit from tokens, ratio, or stricter-of-both
- budget state transitions:
  - `normal`
  - `soft_limit_reached`
  - `near_hard_cap`
  - `forced_fit`
- prepare-turn budget payload contains only:
  - `effective_prompt_budget_tokens`
  - `effective_context_soft_limit_tokens`
  - `estimated_tokens`
  - `budget_state`
- `context_cost` observability includes:
  - effective hard-cap facts
  - raw model/provider caps
  - raw/effective soft-limit facts

**Step 2: Run the targeted budget tests to verify they fail**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/scenarios/dag/agent_core_context_cost_report_test.rb
```

Expected: FAIL because current metadata only records old `context_window_tokens/reserved_output_tokens/decisions`.

**Step 3: Implement budget-state computation**

Update `ContextBudgetManager` to compute and report:
- `runtime.context_window_tokens` as the effective hard cap consumed by the shrink/fit path
- model hard cap
- provider hard cap
- effective hard cap
- effective prompt budget
- raw soft-limit config
- effective soft limit
- `budget_state`

Keep the minimal guidance payload separate from richer `context_cost` observability.

Do not introduce `compact_context_available` yet in this task; that field must be added only after tool visibility masking exists.

**Step 4: Preserve old hard-budget safety belt while removing old `auto_compact` semantics from the main path**

In the same refactor:
- keep drop-memory / prune-tool-outputs / shrink-turns as fit tactics
- stop treating “fit required trimming” as success with no further signal
- classify “fit only after trimming” as `forced_fit`
- keep legacy `auto_compact` behavior out of the new main-path budget contract so later loop tasks can replace it cleanly

**Step 5: Run the targeted tests**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/scenarios/dag/agent_core_context_cost_report_test.rb
```

Expected: PASS.

**Step 6: Commit**

```bash
git add lib/agent_core/dag/context_budget_manager.rb lib/agent_core/runtime_surface/inputs.rb test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/scenarios/dag/agent_core_context_cost_report_test.rb
git commit -m "feat: compute context budget states and guidance"
```

### Task 3: Add Bundled `compact_context` Native Tool, Default Budget Policy Helper, And Dynamic Visibility Masking

**Files:**
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/context_budget/tools.rb`
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/context_budget/default_policy.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/context_budget_manager.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/prompt_assembly.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/resources/tools/policy/profiled.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/cybros/context_budget/default_policy_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/cybros/agent_runtime_resolver_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb`

**Step 1: Write the failing visibility/integration tests**

Cover:
- bundled default policy maps:
  - `normal -> none`
  - `soft_limit_reached -> advise_compact`
  - `near_hard_cap -> enqueue_compact`
  - `forced_fit -> enqueue_compact`
- `compact_context` exists in the canonical registry
- it is hidden from normal model-visible tools
- it becomes visible when the bundled budget policy emits `advise_compact`
- prompt guidance includes `compact_context_available` only after visibility has been resolved for the step
- it is not required to be visible when bundled policy emits `enqueue_compact`

**Step 2: Run the targeted tests to verify they fail**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/lib/cybros/context_budget/default_policy_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/scenarios/dag/agent_core_dag_integration_flow_test.rb
```

Expected: FAIL because `compact_context` is not a registered native tool, there is no bundled policy helper, and there is no dynamic budget-based masking.

**Step 3: Implement the native tool**

Create a native tool that:
- accepts a small argument surface such as `reason` and `target`
- delegates to `Conversation::ContextCompactionPlan` and existing visibility mutation helpers
- returns ordinary `ToolResult.success/error`
- records metadata needed by later observability tests

**Step 4: Implement the bundled policy helper and visibility masking**

Update the runtime/tool-visibility path so:
- Cybros still registers the full canonical tool set
- a distinct bundled default-policy helper maps `budget_state` to `budget_action`
- the bundled default behavior uses that helper output plus budget state in execution context/runtime metadata to decide whether `compact_context` is model-visible for this step
- prompt assembly sends only the masked subset to the model
- the final prompt guidance adds `compact_context_available` only after masking is complete

Do not add a new user-facing configuration field for `near_hard_cap`.

**Step 5: Run the targeted tests**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/lib/cybros/context_budget/default_policy_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/scenarios/dag/agent_core_dag_integration_flow_test.rb
```

Expected: PASS.

**Step 6: Commit**

```bash
git add lib/cybros/context_budget/tools.rb lib/cybros/context_budget/default_policy.rb lib/cybros/agent_runtime_resolver.rb lib/agent_core/dag/context_budget_manager.rb lib/agent_core/dag/prompt_assembly.rb lib/agent_core/resources/tools/policy/profiled.rb test/lib/cybros/context_budget/default_policy_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/scenarios/dag/agent_core_dag_integration_flow_test.rb
git commit -m "feat: add bundled compact_context tool and masking"
```

### Task 4: Integrate Bundled Budget Policy In The DAG Loop And Reclassify Compact Activity

**Files:**
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/executors/task_executor.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/conversation/turn_execution_projector.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/statistics/tool_call_fact_projector.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/conversation/message_run_state_projection_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/conversation/turn_execution_projector_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/conversation/turn_execution_projection_visibility_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/statistics/tool_call_fact_projector_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/cybros/statistics/tool_call_fact_backfill_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/integration/conversation_execution_progress_ui_test.rb`

**Step 1: Write failing loop/projection tests**

Add tests for:
- `soft_limit_reached` -> bundled behavior exposes guidance and model can call `compact_context`
- `near_hard_cap` -> bundled behavior enqueues `compact_context` before the next risky step
- `forced_fit` -> bundled behavior enqueues `compact_context`
- `compact_context` projects as ordinary `tool_call`, not `preflight_task`
- assistant run-state projection no longer suppresses active `compact_context` tasks from the turn activity list
- statistics/facts include the tool call instead of excluding it as preflight

**Step 2: Run the targeted tests to verify they fail**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/models/conversation/message_run_state_projection_test.rb test/models/conversation/turn_execution_projector_test.rb test/models/conversation/turn_execution_projection_visibility_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/cybros/statistics/tool_call_fact_backfill_test.rb test/integration/conversation_execution_progress_ui_test.rb
```

Expected: FAIL because `compact_context` is still treated as preflight, run-state projection still suppresses it, and there is no bundled enqueue path in the agent loop.

**Step 3: Implement bundled loop integration**

Update the loop so the bundled default behavior:
- consumes the bundled default-policy helper output instead of inlining the decision table inside executor logic
- reads budget state from the built prompt / metadata
- allows model choice in `soft_limit_reached`
- inserts a same-turn `task(compact_context)` in `near_hard_cap` and `forced_fit`
- tags inserted tasks with:
  - `source: context_budget_policy`
  - `reason`
  - `budget_fingerprint`

Keep all durable actions on-graph; no silent compaction.

**Step 4: Reclassify compact activity**

Update executors/projectors/statistics so agent-triggered `compact_context` is treated as ordinary tool/task activity.

Legacy historical rows may still exist, but the active path must stop labeling new compact tasks as `preflight_task`.

**Step 5: Run the targeted tests**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/models/conversation/message_run_state_projection_test.rb test/models/conversation/turn_execution_projector_test.rb test/models/conversation/turn_execution_projection_visibility_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/cybros/statistics/tool_call_fact_backfill_test.rb test/integration/conversation_execution_progress_ui_test.rb
```

Expected: PASS.

**Step 6: Commit**

```bash
git add lib/agent_core/dag/executors/agent_message_executor.rb lib/agent_core/dag/executors/task_executor.rb app/models/conversation/turn_execution_projector.rb app/services/statistics/tool_call_fact_projector.rb test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/models/conversation/message_run_state_projection_test.rb test/models/conversation/turn_execution_projector_test.rb test/models/conversation/turn_execution_projection_visibility_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/cybros/statistics/tool_call_fact_backfill_test.rb test/integration/conversation_execution_progress_ui_test.rb
git commit -m "feat: run context compaction inside the agent loop"
```

### Task 5: Retire App-Side Multi-Message Compaction Entry Logic After Loop Replacement Exists

**Files:**
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/conversation.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/conversation/context_compaction_plan.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/agent_profiles.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/context_overflow_compaction_flow_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/conversation/context_compaction_plan_test.rb`

**Step 1: Write the failing flow test for the removal boundary**

Change the scenario so it asserts:
- appending a user turn does not silently insert a durable `compact_context` task before the first agent step
- multi-message compaction is no longer driven by `input_policy.oversize.multi_message.strategy`
- bundled loop-based compaction remains the supported replacement path
- single-message oversize guard behavior remains intact

**Step 2: Run the overflow tests to verify they fail**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/scenarios/dag/context_overflow_compaction_flow_test.rb test/models/conversation/context_compaction_plan_test.rb
```

Expected: FAIL because `append_user_message!` still creates the transient `compact_context` task.

**Step 3: Remove pre-agent multi-message compaction from conversation entry**

Update `Conversation` so:
- `create_user_turn!` and related guarded paths stop calling `maybe_create_compact_context_task!` for multi-message overflow handling
- single-message input guard (`compress_input` / product guard) remains unchanged
- old helper methods that exist only for the app-side multi-message overflow path are removed or narrowed

**Step 4: Re-scope `ContextCompactionPlan`**

Refactor `Conversation::ContextCompactionPlan` so it becomes helper logic for bundled/native compaction work instead of a conversation-entry preflight step.

Keep:
- summary generation helper behavior
- `runtime_surface.compact_context` integration

Remove:
- dependence on `input_policy.oversize.multi_message.strategy`
- assumptions that compaction is triggered directly during `append_user_message!`

**Step 5: Run the targeted tests**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/scenarios/dag/context_overflow_compaction_flow_test.rb test/models/conversation/context_compaction_plan_test.rb
```

Expected: PASS.

**Step 6: Commit**

```bash
git add app/models/conversation.rb app/models/conversation/context_compaction_plan.rb lib/cybros/agent_profiles.rb test/scenarios/dag/context_overflow_compaction_flow_test.rb test/models/conversation/context_compaction_plan_test.rb
git commit -m "refactor: remove app-side context overflow compaction"
```

### Task 6: Add Loop-Suppression Coverage And Final Documentation Updates

**Files:**
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/context_budget/default_policy.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/context_budget_manager.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/public_api.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/behavior_spec.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/context_management.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/node_payloads.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/knowledge_context_memory_design.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/knowledge_context_memory_implementation_plan.md`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/context_overflow_compaction_flow_test.rb`

**Step 1: Write the failing loop-suppression test**

Add a scenario that proves:
- repeated unchanged budget state does not keep re-enqueueing or re-advising `compact_context`
- a `noop` compact attempt suppresses same-fingerprint retries

**Step 2: Run the loop-suppression tests to verify they fail**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/scenarios/dag/context_overflow_compaction_flow_test.rb
```

Expected: FAIL because there is no stable `budget_fingerprint` suppression path yet.

**Step 3: Implement fingerprint suppression and doc updates**

Update code and docs to describe the final shipped behavior:
- provider hard cap + model hard cap + model soft limit
- minimal guidance payload
- bundled agent-program defaults vs kernel responsibilities
- ordinary DAG task semantics for `compact_context`
- explicit exclusion of agent-contributed tools as follow-up work
- move any docs that still need to retain the old `auto_compact`-first story into `docs/archive` instead of leaving that vocabulary in active docs
- remove obsolete compact-specific dead code and compatibility branches that became unnecessary after the cut

**Step 4: Run the focused tests**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/scenarios/dag/context_overflow_compaction_flow_test.rb
```

Expected: PASS.

**Step 5: Run the broader verification sweep**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/lib/cybros/llm/catalog_test.rb test/lib/cybros/context_budget/default_policy_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/scenarios/dag/agent_core_context_cost_report_test.rb test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/scenarios/dag/context_overflow_compaction_flow_test.rb test/models/conversation/context_compaction_plan_test.rb test/models/conversation/message_run_state_projection_test.rb test/models/conversation/turn_execution_projector_test.rb test/models/conversation/turn_execution_projection_visibility_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/cybros/statistics/tool_call_fact_backfill_test.rb test/integration/conversation_execution_progress_ui_test.rb
```

Expected: PASS.

Then run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && rg -n "auto_compact|preflight_task|input_policy\\.oversize\\.multi_message\\.strategy" docs/agent_core docs/product docs/dag -g '!docs/archive/**'
```

Expected: no active-doc hits for the old main-path story; any doc that still needs the historical vocabulary must be moved under `docs/archive`.

Then run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && rg -n "maybe_create_compact_context_task!|input_policy\\.oversize\\.multi_message\\.strategy|PREFLIGHT_TOOL_NAMES = %w\\[compress_input compact_context\\]|compact_context.*preflight_task|auto_compact" app lib
```

Expected: no active-path hits for the removed compact flow, except intentionally retained legacy helpers that are explicitly marked and justified in code comments.

**Step 6: Commit**

```bash
git add lib/cybros/context_budget/default_policy.rb lib/agent_core/dag/context_budget_manager.rb lib/agent_core/dag/executors/agent_message_executor.rb docs/agent_core/public_api.md docs/agent_core/behavior_spec.md docs/agent_core/context_management.md docs/agent_core/node_payloads.md docs/agent_core/knowledge_context_memory_design.md docs/agent_core/knowledge_context_memory_implementation_plan.md test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/scenarios/dag/context_overflow_compaction_flow_test.rb
git commit -m "feat: finalize context budget soft limit behavior"
```

### Follow-Up (Not In This Plan)

Do not add this work to the current implementation batch:
- agent-program-contributed tool implementations / MCP adapters / skills overlays inside the canonical loop
- runtime-time “ask the agent whether it implements this tool” fallback routing

If pursued later, design it as a Cybros-owned public tool-extension surface with registration-time merge and conflict rules, not as an execution-time fallback heuristic.
