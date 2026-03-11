# Programmable Agent Rebaseline Repair Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** close the fixable programmable-agent rebaseline audit items in controlled repair batches without reopening already-settled product semantics.

**Architecture:** keep each repair pinned to the audit evidence and the existing implementation plans. Use red-green changes for every PA item, keep batch boundaries small, and gate each batch on targeted verification plus code review before moving forward.

**Tech Stack:** Ruby 4.0.1, Rails 8.2 alpha, Minitest, Active Job, programmable-agent fixture server

---

## Scope

**In scope for this repair session**

- Batch 1: `PA-004`, `PA-005`, `PA-008`, `PA-010`, `PA-013`
- Batch 2 if Batch 1 is stable: `PA-001`, `PA-003`, `PA-007`, `PA-009`
- Dedicated later batch or explicit carry-forward: `PA-002`

**Explicitly excluded from implementation in this session**

- `PA-006`
- `PA-011`
- `PA-012`

These three stay in the audit as open discussion or acceptance-alignment items unless fresh evidence later proves they became directly fixable inside the scoped repair work.

### Task 1: PA-004 Replay Binding Must Include `agent_deployment_id`

**Files:**
- Modify: `cybros/test/integration/agent_rpc_invocation_replay_test.rb`
- Modify: `cybros/test/models/agent_rpc_invocation_test.rb`
- Modify: `cybros/app/models/agent_rpc_invocation.rb`
- Modify: `cybros/app/services/agent_rpc/invocation_store.rb`
- Modify: `cybros/db/schema.rb`
- Create: `cybros/db/migrate/20260309000017_pin_agent_rpc_invocation_replay_to_agent_deployment.rb`

**Step 1: Write the failing tests**

Add coverage that reuses the same `invocation_id` against a second deployment row with copied binding fields and proves Cybros must create a distinct invocation instead of replaying the first one.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/agent_rpc_invocation_test.rb test/integration/agent_rpc_invocation_replay_test.rb`

Expected: FAIL because replay lookup and uniqueness are still keyed only by fingerprint + activation epoch.

**Step 3: Write minimal implementation**

Pin replay identity to `agent_deployment_id` in both the model uniqueness boundary and the replay lookup/equality check, then update the unique index accordingly.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/agent_rpc_invocation_test.rb test/integration/agent_rpc_invocation_replay_test.rb`

Expected: PASS

### Task 2: PA-005 And PA-008 Deployment Inspection/Activation Gates

**Files:**
- Modify: `cybros/test/integration/agent_deployments_inspection_test.rb`
- Modify: `cybros/test/integration/agent_deployments_activation_gate_test.rb`
- Modify: `cybros/app/services/agent_deployments/inspection_service.rb`
- Modify: `cybros/app/services/agent_deployments/activation_service.rb`

**Step 1: Write the failing tests**

Add one test where `initialize` omits `protocol_version` and activation must reject it. Add one test where `agent.health` returns `{ healthy: true, status: "ok" }` and activation must still succeed after inspection normalizes success.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/agent_deployments_inspection_test.rb test/integration/agent_deployments_activation_gate_test.rb`

Expected: FAIL because inspection currently falls back to the seeded protocol version and activation only accepts the literal `"healthy"` status.

**Step 3: Write minimal implementation**

Require explicit negotiated `protocol_version` from `initialize` during inspection, and normalize successful health checks to the stable internal `"healthy"` state before activation/selectability logic runs.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/agent_deployments_inspection_test.rb test/integration/agent_deployments_activation_gate_test.rb`

Expected: PASS

### Task 3: PA-010 Interactive Planning-Time Config Reads Must Be Draft-Bound

**Files:**
- Modify: `cybros/test/integration/run_draft_finalization_test.rb`
- Modify: `cybros/app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `cybros/app/services/agent_rpc/kernel_services/conversation_config.rb`

**Step 1: Write the failing tests**

Add coverage proving that planning-time `agent_config` payloads and `conversation.config.get` both read the namespace for `draft.agent_program`, even if the live conversation selection changes before finalization.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/run_draft_finalization_test.rb`

Expected: FAIL because the conversation path still reads `conversation.selected_agent_config`.

**Step 3: Write minimal implementation**

Route both planning payload construction and kernel `conversation.config.get` through `conversation.selected_agent_config_for(draft.agent_program)`.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/run_draft_finalization_test.rb`

Expected: PASS

### Task 4: PA-013 Failed Provider Attempts Must Stay In Rolling Window Accounting

**Files:**
- Modify: `cybros/test/services/runtime_governance/provider_budget_reservations_test.rb`
- Modify: `cybros/app/services/runtime_governance/provider_budget_reservations.rb`

**Step 1: Write the failing test**

Add a regression showing a failed request that gets released still consumes the rolling RPM/TPM window long enough to block another immediate request.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/runtime_governance/provider_budget_reservations_test.rb`

Expected: FAIL because released reservations currently disappear from rolling-window calculations.

**Step 3: Write minimal implementation**

Keep released failure reservations inside rolling-window accounting while still freeing concurrent capacity.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/runtime_governance/provider_budget_reservations_test.rb`

Expected: PASS

### Task 5: Batch 1 Verification And Review Gate

**Files:**
- Review: `cybros/test/models/agent_rpc_invocation_test.rb`
- Review: `cybros/test/integration/agent_rpc_invocation_replay_test.rb`
- Review: `cybros/test/integration/agent_deployments_inspection_test.rb`
- Review: `cybros/test/integration/agent_deployments_activation_gate_test.rb`
- Review: `cybros/test/integration/run_draft_finalization_test.rb`
- Review: `cybros/test/services/runtime_governance/provider_budget_reservations_test.rb`

**Step 1: Run targeted Batch 1 verification**

Run: `bin/rails test test/models/agent_rpc_invocation_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/agent_deployments_inspection_test.rb test/integration/agent_deployments_activation_gate_test.rb test/integration/run_draft_finalization_test.rb test/services/runtime_governance/provider_budget_reservations_test.rb`

Expected: PASS

**Step 2: Request code review on the Batch 1 diff**

Dispatch a focused reviewer over the Batch 1 file set and capture any blocking findings before proceeding.

**Step 3: Apply reviewer feedback one item at a time**

Use `receiving-code-review`. Verify each accepted fix with the narrowest relevant test before batching a final rerun.

**Step 4: Rerun targeted Batch 1 verification**

Run the same command from Step 1.

Expected: PASS

### Task 6: Batch 2 Tests For PA-001, PA-003, PA-007, And PA-009

**Files:**
- Modify: `cybros/test/integration/run_draft_target_switch_test.rb`
- Modify: `cybros/test/integration/run_draft_approval_resume_test.rb`
- Modify: `cybros/test/integration/agent_deployments_activation_gate_test.rb`
- Modify: `cybros/test/integration/automation_conversation_binding_test.rb`
- Modify: other focused integration tests as required by the narrow fix

**Step 1: Write failing tests for each PA item before production code**

Keep one failure mode per test:
- `PA-001`: `execution_target.propose` must force kernel-owned approval parking on `confirm`
- `PA-003`: permission mode changes after parking must not stale the parked draft
- `PA-007`: `turn.handle_error` must be required and invoked on runtime failure path
- `PA-009`: conversation-bound automation callbacks and approval sync must resolve the bound conversation canonically

**Step 2: Run the narrow failing tests**

Run only the tests for the PA item being implemented.

Expected: FAIL for the intended reason

**Step 3: Write minimal implementation**

Keep each PA item isolated; do not bundle unrelated cleanups.

**Step 4: Run the narrow tests again**

Expected: PASS

### Task 7: Batch 2 Verification And Review Gate

**Files:**
- Review only the Batch 2 diff after implementation stabilizes

**Step 1: Run targeted Batch 2 verification**

Run: `bin/rails test test/integration/run_draft_target_switch_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/agent_deployments_activation_gate_test.rb test/integration/automation_conversation_binding_test.rb`

Expected: PASS once the batch is complete

**Step 2: Request code review on the Batch 2 diff**

Dispatch a focused reviewer over only the Batch 2 changes.

**Step 3: Apply validated reviewer feedback**

Use `receiving-code-review` and rerun the narrow failing test after each accepted change.

**Step 4: Rerun targeted Batch 2 verification**

Run the same command from Step 1.

Expected: PASS

### Task 8: PA-002 Carry-Forward Decision

**Files:**
- Modify: `cybros/docs/audits/programmable-agent-rebaseline-audit.md`

**Step 1: Decide whether there is enough verified time/scope to repair PA-002 in a dedicated later batch**

If not, record it explicitly as still open with the reason it was not included in this session’s implemented batches.

**Step 2: Keep the audit accurate**

Mark only fully closed PA items as closed. Leave unresolved items, discussion items, and excluded items visible.

### Task 9: Final Verification And Session Closeout

**Files:**
- Modify: `cybros/docs/audits/programmable-agent-rebaseline-audit.md`
- Review: `git status --short`

**Step 1: Run final verification commands for all completed batches**

At minimum rerun every targeted command used to justify closed PA items.

**Step 2: Capture current git status**

Run: `git status --short`

**Step 3: Report only verified outcomes**

List:
- closed PA items
- open PA items
- exact commands run and exit results
- current git status
- residual risk
