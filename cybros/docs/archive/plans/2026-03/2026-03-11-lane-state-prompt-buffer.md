# Lane-Scoped State and Prompt Buffer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace conversation-global programmable-agent mutable state with lane-scoped state, add a token-aware `lane.prompt_buffer` public API, and migrate both context-working-set behavior and default agent context management toward the new lane-state model.

**Architecture:** DAG remains the durable source of truth for history, tasks, branches, and audit. Branch-local programmable state moves to lane-scoped persistence (`lane_kv_entries` and `lane_prompt_buffer_entries`) with frozen-snapshot fork semantics and explicit merge through a normal DAG task. Token estimation becomes a first-class public API, the bundled/default agent context manager renders prompt-side summaries/notes/handoff material from `lane.prompt_buffer`, and prompt-working-set logic migrates away from conversation-global KV assumptions.

**Tech Stack:** Rails 8.2 alpha, Ruby 4.0.1, PostgreSQL 18, ActiveRecord, existing DAG engine / Agent RPC / AgentCore runtime stack.

---

## Destructive-Cut Assumptions

- This plan is intentionally destructive.
- Do not preserve compatibility aliases, dual paths, or storage-level translation shims unless the same batch proves they are still required.
- `db:reset` remains an acceptable way to land the cut.
- Old behavior must be fully migrated onto the new system, not left half-alive behind wrappers.
- After the cut, superseded concept names are allowed only in explicitly archived docs under `docs/archive`.

### Task 1: Replace conversation-global KV schema with lane-scoped state tables

**Files:**
- Delete/Rename: `/Users/jasl/Workspaces/Cybros/cybros/cybros/db/migrate/20260309000011_create_conversation_kv_entries.rb`
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/db/migrate/20260309000011_create_lane_kv_entries.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/db/schema.rb`
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/db/migrate/20260311000012_create_lane_prompt_buffer_entries.rb`
- Delete: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/conversation_kv_entry.rb`
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/lane_kv_entry.rb`
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/lane_prompt_buffer_entry.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/lane_kv_entry_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/lane_prompt_buffer_entry_test.rb`

**Step 1: Write the failing model/schema tests**

- Add tests proving:
  - `LaneKvEntry` belongs to `DAG::Lane`, requires nonblank key, normalizes JSON, and is unique per lane.
  - `LanePromptBufferEntry` belongs to `DAG::Lane`, requires nonblank `buffer_name`, positive `seq`, nonblank `content`, and stores `estimated_tokens`.
  - prompt-buffer entries order correctly by `seq`.

**Step 2: Run the targeted tests to verify failure**

Run:

```bash
bin/rails test test/models/lane_kv_entry_test.rb test/models/lane_prompt_buffer_entry_test.rb
```

Expected: FAIL because the models/tables do not exist yet.

**Step 3: Write the minimal schema and models**

- Replace the old `conversation_kv_entries` migration content so it creates `lane_kv_entries` keyed by `lane_id`.
- Rename the migration file so the filename and table name stay aligned after the cut.
- Add a new migration for `lane_prompt_buffer_entries`.
- Delete `ConversationKVEntry` and add the two new models with normalization/validation logic.
- Keep string-key JSON normalization and writer attribution semantics where still useful.

**Step 4: Reset the database and regenerate schema**

Run:

```bash
bin/rails db:reset
```

Expected: PASS, with `schema.rb` now containing `lane_kv_entries` and `lane_prompt_buffer_entries`, and no `conversation_kv_entries` table.

**Step 5: Run the targeted tests to verify pass**

Run:

```bash
bin/rails test test/models/lane_kv_entry_test.rb test/models/lane_prompt_buffer_entry_test.rb
```

Expected: PASS.

**Step 6: Commit**

```bash
git add db/migrate/20260309000011_create_lane_kv_entries.rb db/migrate/20260311000012_create_lane_prompt_buffer_entries.rb db/schema.rb app/models/lane_kv_entry.rb app/models/lane_prompt_buffer_entry.rb test/models/lane_kv_entry_test.rb test/models/lane_prompt_buffer_entry_test.rb
git rm db/migrate/20260309000011_create_conversation_kv_entries.rb app/models/conversation_kv_entry.rb
git commit -m "feat: add lane scoped state tables"
```

### Task 2: Attach lane-scoped state to the Conversation/DAG domain

**Files:**
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/conversation.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/dag/lane.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/dag/lane_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/conversation_chat_facade_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/lane_branch_and_merge_flow_test.rb`

**Step 1: Write the failing domain tests**

- Add tests proving:
  - a lane exposes `lane_kv_entries` and `lane_prompt_buffer_entries`
  - `Conversation#chat_lane` is the scope used for branch-local state
  - `Conversation#create_child!` snapshots branch-local state at fork time
  - a forked lane starts from a frozen snapshot contract, not a live parent lookup
  - parent-lane writes after fork are not visible to the child conversation

**Step 2: Run the targeted tests to verify failure**

Run:

```bash
bin/rails test test/models/dag/lane_test.rb test/models/conversation_chat_facade_test.rb test/scenarios/dag/lane_branch_and_merge_flow_test.rb
```

Expected: FAIL on missing associations/helpers.

**Step 3: Add the minimal associations and snapshot plumbing**

- Add `has_many` associations from `DAG::Lane`.
- Add any required convenience methods on `Conversation` for resolving the active lane-scoped state owner.
- Introduce explicit snapshot helpers for lane-state export at fork time.
- Wire the snapshot contract through the real `Conversation#create_child!` branch-creation flow rather than only through helper-level exports.
- Do **not** implement live parent-overlay reads.

**Step 4: Run the targeted tests to verify pass**

Run:

```bash
bin/rails test test/models/dag/lane_test.rb test/models/conversation_chat_facade_test.rb test/scenarios/dag/lane_branch_and_merge_flow_test.rb
```

Expected: PASS.

**Step 5: Commit**

```bash
git add app/models/conversation.rb app/models/dag/lane.rb test/models/dag/lane_test.rb test/models/conversation_chat_facade_test.rb test/scenarios/dag/lane_branch_and_merge_flow_test.rb
git commit -m "feat: attach lane scoped state to lanes"
```

### Task 3: Replace `conversation.kv.*` with `lane.kv.*` in the public programmable-agent surface

**Files:**
- Delete: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/conversation_kv.rb`
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/lane_kv.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/callback_dispatcher.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/finalize_service.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/runtime_governance/public_state_mutation_policy.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/programmable_agent_fixture.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/integration/run_draft_finalization_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/integration/run_draft_approval_resume_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/integration/agent_rpc_session_auth_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/agent_rpc_operation_receipt_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/services/runtime_governance/public_state_mutation_policy_test.rb`

**Step 1: Write the failing API tests**

- Update tests to expect `lane.kv.get/set/delete/list/snapshot`.
- Remove expectations for `conversation.kv.*`.
- Add a proof that staged mutations apply against the active lane, not the conversation globally.

**Step 2: Run the targeted tests to verify failure**

Run:

```bash
bin/rails test test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/agent_rpc_session_auth_test.rb test/models/agent_rpc_operation_receipt_test.rb test/services/runtime_governance/public_state_mutation_policy_test.rb
```

Expected: FAIL because callbacks and staging still use conversation-global KV.

**Step 3: Implement `lane.kv.*` and delete the old live path**

- Add `AgentRPC::KernelServices::LaneKV`.
- Update callback dispatch, allowed callback method lists, staged-operation finalization, and runtime governance policy names.
- Migrate fixtures and helper receipts to the new method names.
- Delete `conversation.kv.*` instead of leaving alias endpoints.

**Step 4: Run the targeted tests to verify pass**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add app/services/agent_rpc/kernel_services/lane_kv.rb app/services/agent_rpc/callback_dispatcher.rb app/services/run_drafts/conversation_turn_planning_service.rb app/services/run_drafts/finalize_service.rb app/services/runtime_governance/public_state_mutation_policy.rb lib/cybros/programmable_agent_fixture.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/agent_rpc_session_auth_test.rb test/models/agent_rpc_operation_receipt_test.rb test/services/runtime_governance/public_state_mutation_policy_test.rb
git rm app/services/agent_rpc/kernel_services/conversation_kv.rb
git commit -m "feat: replace conversation kv with lane kv"
```

### Task 4: Add the `lane.prompt_buffer.*` and `tokens.*` public APIs

**Files:**
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/lane_prompt_buffer.rb`
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/tokens.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/callback_dispatcher.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/runtime_surface/helpers.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/agent_runtime_resolver.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/services/agent_rpc/kernel_services/lane_prompt_buffer_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/services/agent_rpc/kernel_services/tokens_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/agent_core/runtime_surface_runner_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/cybros/agent_runtime_resolver_test.rb`

**Step 1: Write the failing API tests**

- Add tests proving:
  - `lane.prompt_buffer.put/list/get/delete/clear/snapshot`
  - `lane.prompt_buffer.render(max_tokens:)` selects entries by priority/newness but returns them in ascending `seq`
  - oversized entries are reported, not silently partially truncated
  - `tokens.estimate_text` and `tokens.estimate_messages` route through the runtime token counter
  - the API shape is sufficient for default context-manager sections such as `summaries`, `working_notes`, and `handoff`

**Step 2: Run the targeted tests to verify failure**

Run:

```bash
bin/rails test test/services/agent_rpc/kernel_services/lane_prompt_buffer_test.rb test/services/agent_rpc/kernel_services/tokens_test.rb test/lib/agent_core/runtime_surface_runner_test.rb test/lib/cybros/agent_runtime_resolver_test.rb
```

Expected: FAIL because the new APIs and helpers do not exist yet.

**Step 3: Implement the minimal public APIs**

- Add `LanePromptBuffer` and `Tokens` kernel services.
- Wire callback dispatch and allowed callback method lists.
- Expand runtime helper / resolver plumbing only as needed for token estimation reuse.
- Keep `estimate_prompt` out of the cut.

**Step 4: Run the targeted tests to verify pass**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add app/services/agent_rpc/kernel_services/lane_prompt_buffer.rb app/services/agent_rpc/kernel_services/tokens.rb app/services/agent_rpc/callback_dispatcher.rb app/services/run_drafts/conversation_turn_planning_service.rb lib/agent_core/runtime_surface/helpers.rb lib/cybros/agent_runtime_resolver.rb test/services/agent_rpc/kernel_services/lane_prompt_buffer_test.rb test/services/agent_rpc/kernel_services/tokens_test.rb test/lib/agent_core/runtime_surface_runner_test.rb test/lib/cybros/agent_runtime_resolver_test.rb
git commit -m "feat: add lane prompt buffer and token apis"
```

### Task 5: Migrate default agent context management, compaction, and context-working-set logic toward lane prompt buffers

**Files:**
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/conversation/context_compaction_plan.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/context_adapter.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/context_budget_manager.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/prompt_assembly.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-11-context-budget-soft-limit-design.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-11-context-budget-soft-limit.md`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/context_overflow_compaction_flow_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/agent_core/dag/prompt_assembly_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/statistics/tool_call_fact_projector_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/agent_core_context_cost_report_test.rb`

**Step 1: Write the failing flow tests**

- Add or update scenario coverage proving:
  - the bundled/default agent context manager renders prompt-side summaries/notes/handoff from `lane.prompt_buffer` rather than from legacy conversation-global or DAG-only summary assumptions
  - prompt summaries/notes now come from `lane.prompt_buffer` where appropriate
  - `compact_context` updates prompt-working-set state without requiring every summary to be a DAG summary node
  - existing compaction audit/task semantics stay on the DAG
  - existing hard/soft context-budget behavior still holds after the migration:
    - hard budget authority remains `runtime.context_window_tokens`
    - soft-limit calculation still uses `context_soft_limit_tokens` / `context_soft_limit_ratio`
    - `budget_state` and `budget_action` still transition correctly after `lane.prompt_buffer` material enters the prompt
    - `context_cost` still reports model/provider/effective hard-cap and soft-limit observability fields correctly

**Step 2: Run the targeted tests to verify failure**

Run:

```bash
bin/rails test test/scenarios/dag/context_overflow_compaction_flow_test.rb test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb test/lib/agent_core/dag/prompt_assembly_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/scenarios/dag/agent_core_context_cost_report_test.rb
```

Expected: FAIL because compaction, prompt assembly, and default context management still assume the older history-only working-set model.

**Step 3: Implement the minimal migration**

- Update compaction planning, prompt assembly, and default context-management assembly to use `lane.prompt_buffer` as the prompt-working-set substrate.
- Make the bundled/default context manager render prompt-side sections such as summaries/notes/handoff from `lane.prompt_buffer` before budget evaluation runs.
- Preserve DAG task/audit materialization for `compact_context`.
- Keep DAG summary-node compaction only where durable historical compaction is truly intended.
- Treat this task as the explicit migration proof for the already-implemented context-budget redesign:
  - do not redesign hard/soft budget policy again
  - migrate the existing hard/soft budget machinery so it consumes the new prompt-working-set model cleanly
  - update the context-budget design/plan docs so they explicitly describe `lane.prompt_buffer` as the prompt-working-set layer beneath soft/hard budget evaluation
- Replace, rather than supplement, the old history-only prompt-working-set assumptions on the active path.

**Step 4: Run the targeted tests to verify pass**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add app/models/conversation/context_compaction_plan.rb lib/agent_core/dag/context_adapter.rb lib/agent_core/dag/context_budget_manager.rb lib/agent_core/dag/prompt_assembly.rb lib/agent_core/dag/executors/agent_message_executor.rb docs/plans/2026-03-11-context-budget-soft-limit-design.md docs/plans/2026-03-11-context-budget-soft-limit.md test/scenarios/dag/context_overflow_compaction_flow_test.rb test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb test/lib/agent_core/dag/prompt_assembly_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/scenarios/dag/agent_core_context_cost_report_test.rb
git commit -m "feat: move prompt working set to lane prompt buffers"
```

### Task 6: Implement explicit lane-state merge and frozen-snapshot semantics

**Files:**
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/conversation.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/dag/mutations.rb`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/agent_runtime_resolver.rb`
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/lane_state/tools.rb`
- Create: `/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/lane_state/merge_result_applier.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/dag/lane_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/models/conversation_chat_facade_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/lib/agent_core/dag/task_executor_runtime_surface_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/lane_state_merge_flow_test.rb`
- Test: `/Users/jasl/Workspaces/Cybros/cybros/cybros/test/scenarios/dag/lane_branch_and_merge_flow_test.rb`

**Step 1: Write the failing merge tests**

- Add tests proving:
  - `Conversation#merge_into_parent!` no longer materializes an `agent_message` placeholder; it creates an executable `merge_lane_state` task boundary
  - merge input uses frozen snapshots, not live lane reads
  - applying task output patches mutates only the target lane state
  - the merge task executes through the ordinary task/runtime contract
  - source-lane archival remains an explicit choice

**Step 2: Run the targeted tests to verify failure**

Run:

```bash
bin/rails test test/models/dag/lane_test.rb test/models/conversation_chat_facade_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/scenarios/dag/lane_state_merge_flow_test.rb test/scenarios/dag/lane_branch_and_merge_flow_test.rb
```

Expected: FAIL because merge does not yet include lane-state semantics.

**Step 3: Implement the minimal merge path**

- Keep `DAG::Mutations#merge_lanes!` as the structural join primitive.
- Make the product-level merge node a task-shaped merge boundary.
- Migrate `Conversation#merge_into_parent!` onto that task boundary instead of leaving the current `Messages::AgentMessage` join path in place.
- Register a default `merge_lane_state` runtime/tool implementation so the task is actually executable through the standard task executor.
- Add a small applier object for validated lane-state patches.
- Do **not** add a merge-specific hook in this cut.

**Step 4: Run the targeted tests to verify pass**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add app/models/conversation.rb lib/dag/mutations.rb lib/cybros/agent_runtime_resolver.rb lib/cybros/lane_state/tools.rb app/services/lane_state/merge_result_applier.rb test/models/dag/lane_test.rb test/models/conversation_chat_facade_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/scenarios/dag/lane_state_merge_flow_test.rb test/scenarios/dag/lane_branch_and_merge_flow_test.rb
git commit -m "feat: add explicit lane state merge task"
```

### Task 7: Delete superseded docs and finish verification

**Files:**
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/public_api.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/context_management.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/behavior_spec.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product/kernel_service_surface.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product/agent_rpc.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product/domain_model.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/product/execution_model.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/dag/audit.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/knowledge_context_memory_design.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/agent_core/knowledge_context_memory_implementation_plan.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-11-context-budget-soft-limit-design.md`
- Modify: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-11-context-budget-soft-limit.md`
- Move or Rewrite: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-11-lane-state-prompt-buffer-design.md`
- Move or Rewrite: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-11-lane-state-prompt-buffer.md`
- Move or Rewrite: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-10-bundled-default-external-agent-design.md`
- Move or Rewrite: `/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/audits/programmable-agent-rebaseline-audit.md`

**Step 1: Write the failing doc audit**

- Build a grep list that should no longer appear in active docs/code once the cut is done:
  - `conversation.kv.`
  - `ConversationKVEntry`
  - `conversation_kv_entries`
  - old `topic` phrasing where it is used as a branch-conversation concept
  - prose that implies prompt summaries only live as DAG summary nodes
  - prose that still presents DAG history alone as the full prompt-working-set story
  - old active-path compact/budget entrypoints and preflight-only compact semantics

**Step 2: Run the doc/code audit to verify failures**

Run:

```bash
rg -n "conversation\\.kv\\.|ConversationKVEntry|conversation_kv_entries|branch lane/topic" app lib docs test -g '!docs/archive/**'
```

Expected: FAIL with hits in old APIs, docs, and tests.

**Step 3: Rewrite docs and remove stale language**

- Update public API docs to `lane.kv.*`, `lane.prompt_buffer.*`, and `tokens.*`.
- Update context docs to the new three-layer model:
  - DAG history window
  - lane prompt buffer
  - token budget
- Update or archive any remaining active plan/audit docs that still require historical old vocabulary.
- Do not leave superseded concept names in active docs as “known legacy” exceptions; if a doc must retain them for historical reasons, move it under `docs/archive`.
- This includes the completed migration plan/design docs for this cut if they still need to mention the superseded vocabulary for historical context.

**Step 4: Run full verification**

Run:

```bash
bin/rails db:reset
PARALLEL_WORKERS=1 bin/rails test test/models/lane_kv_entry_test.rb test/models/lane_prompt_buffer_entry_test.rb test/models/dag/lane_test.rb test/models/conversation_chat_facade_test.rb test/services/agent_rpc/kernel_services/lane_prompt_buffer_test.rb test/services/agent_rpc/kernel_services/tokens_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/agent_rpc_session_auth_test.rb test/models/agent_rpc_operation_receipt_test.rb test/services/runtime_governance/public_state_mutation_policy_test.rb test/scenarios/dag/context_overflow_compaction_flow_test.rb test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/scenarios/dag/lane_state_merge_flow_test.rb test/scenarios/dag/lane_branch_and_merge_flow_test.rb test/scenarios/dag/agent_core_context_cost_report_test.rb test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb test/lib/agent_core/dag/prompt_assembly_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/agent_core/runtime_surface_runner_test.rb test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/lib/cybros/agent_runtime_resolver_test.rb
```

Expected: PASS.

Run:

```bash
rg -n "conversation\\.kv\\.|ConversationKVEntry|conversation_kv_entries|branch lane/topic" app lib test db/schema.rb docs -g '!docs/archive/**'
rg -n "maybe_create_compact_context_task!|input_policy\\.oversize\\.multi_message\\.strategy|PREFLIGHT_TOOL_NAMES = %w\\[compress_input compact_context\\]|compact_context.*preflight_task|auto_compact" app lib docs test -g '!docs/archive/**'
```

Expected: no active hits outside explicitly archived references.

**Step 5: Request code review**

- Use the `requesting-code-review` skill on the completed branch.

**Step 6: Commit**

```bash
git add docs/agent_core/public_api.md docs/agent_core/context_management.md docs/agent_core/behavior_spec.md docs/product/kernel_service_surface.md docs/product/agent_rpc.md docs/product/domain_model.md docs/product/execution_model.md docs/dag/audit.md docs/agent_core/knowledge_context_memory_design.md docs/agent_core/knowledge_context_memory_implementation_plan.md docs/plans/2026-03-11-context-budget-soft-limit-design.md docs/plans/2026-03-11-context-budget-soft-limit.md docs/archive
git commit -m "docs: adopt lane scoped prompt state model"
```
