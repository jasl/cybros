# Automation / Conversation Convergence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove `AutomationRun` and converge automation execution onto `Automation -> Conversation -> RunDraft -> ConversationRun`, with one fresh conversation per automation trigger.

**Architecture:** Automations stop carrying runtime identity and stop reusing existing conversations. Dispatch creates one execution conversation per trigger, conversation-first planning/finalization is reused, and `ConversationRun` remains the only run record while `RunDraft` remains the only pre-run planning state.

**Tech Stack:** Ruby on Rails, PostgreSQL, ActiveJob, DAG runtime, product docs under `docs/product/`

> Status note (2026-03-10): this convergence has landed. This document now serves as the implementation record and audit checklist. Any line that says "Historical red-phase expectation" describes the original failing-test phase before the cut was applied.

---

### Task 1: Rewrite Schema Ownership Around Conversation Execution Instances

**Files:**
- Modify: `db/schema.rb`
- Modify: create-migration files that currently define `automations`, `automation_runs`, `conversations`, and `run_drafts`
- Modify: `app/models/automation.rb`
- Modify: `app/models/conversation.rb`
- Modify: `app/models/run_draft.rb`
- Modify: `app/models/conversation_run.rb`
- Delete: `app/models/automation_run.rb`
- Test: `test/models/automation_test.rb`
- Test: `test/models/run_draft_test.rb`
- Test: `test/models/conversation_run_test.rb`

**Step 1: Write the failing schema/model tests**

Cover:

- `Automation` no longer accepts or exposes `conversation_id`
- `Conversation` can belong to an automation via explicit lineage fields
- `RunDraft` requires `conversation_id` and no longer accepts `automation_id`
- `ConversationRun` no longer exposes `has_one :automation_run`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/automation_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb`

Historical red-phase expectation: FAIL on removed/changed associations and new required conversation lineage.

**Step 3: Write the minimal schema/model implementation**

Implement:

- remove `automations.conversation_id`
- drop `automation_runs`
- add `conversations.automation_id`
- add `conversations.automation_dispatch_key`
- add `conversations.automation_triggered_at`
- add unique index on `(automation_id, automation_dispatch_key)` where the key is present
- remove the run-draft dual-entrypoint check and require `conversation_id`
- remove `ConversationRun` links to `AutomationRun`

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/automation_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add db/schema.rb db/migrate app/models/automation.rb app/models/conversation.rb app/models/run_draft.rb app/models/conversation_run.rb test/models/automation_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb
git commit -m "refactor: make conversations the automation execution container"
```

### Task 2: Replace `AutomationRun` Dispatch With Conversation-Instance Dispatch

**Files:**
- Modify: `app/services/automations/dispatch.rb`
- Modify: `app/services/automations/scheduler.rb`
- Modify: `app/jobs/automations/dispatch_due_job.rb`
- Delete or replace: `app/jobs/automations/execute_run_job.rb`
- Create: `app/jobs/automations/execute_conversation_job.rb`
- Test: `test/services/automations/dispatch_test.rb`
- Test: `test/jobs/automations/dispatch_due_job_test.rb`
- Test: `test/integration/automation_scheduler_flow_test.rb`

**Step 1: Write the failing dispatch tests**

Cover:

- one trigger creates one execution conversation
- repeated dispatch with the same `dispatch_key` reuses that execution conversation instead of creating a second one
- scheduler history is now conversation-backed instead of `AutomationRun`-backed

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/automations/dispatch_test.rb test/jobs/automations/dispatch_due_job_test.rb test/integration/automation_scheduler_flow_test.rb`

Historical red-phase expectation: FAIL because dispatch still creates `AutomationRun` and the job still claims `automation_run_id`.

**Step 3: Write the minimal dispatch implementation**

Implement:

- `Automations::Dispatch` finds or creates the execution conversation by `(automation_id, automation_dispatch_key)`
- the new conversation is seeded from automation defaults
- dispatch enqueues `Automations::ExecuteConversationJob` with `conversation_id`
- scheduler returns execution conversations, not automation runs

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/automations/dispatch_test.rb test/jobs/automations/dispatch_due_job_test.rb test/integration/automation_scheduler_flow_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/automations/dispatch.rb app/services/automations/scheduler.rb app/jobs/automations/dispatch_due_job.rb app/jobs/automations/execute_conversation_job.rb test/services/automations/dispatch_test.rb test/jobs/automations/dispatch_due_job_test.rb test/integration/automation_scheduler_flow_test.rb
git commit -m "refactor: dispatch automations into execution conversations"
```

### Task 3: Collapse Automation Planning Onto The Conversation-First RunDraft Path

**Files:**
- Delete: `app/services/automations/run_orchestrator.rb`
- Delete: `app/services/automations/run_state_recorder.rb`
- Delete or replace: `app/services/run_drafts/automation_planning_service.rb`
- Modify: `app/services/run_drafts/conversation_turn_orchestrator.rb`
- Modify: `app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `app/services/run_drafts/finalize_service.rb`
- Modify: `app/services/run_drafts/approval_resume_service.rb`
- Modify: `app/services/run_drafts/approval_expiry_service.rb`
- Modify: `app/models/conversation.rb`
- Modify: `app/models/conversation_run_tracker.rb`
- Test: `test/integration/automation_execution_run_draft_flow_test.rb`
- Test: `test/integration/run_draft_finalization_test.rb`
- Test: `test/integration/run_draft_approval_resume_test.rb`
- Test: `test/integration/automation_failure_recovery_test.rb`

**Step 1: Write the failing lifecycle tests**

Cover:

- automation execution opens a conversation-scoped `RunDraft`
- approval parks the draft and the execution conversation's pending node
- successful finalization always materializes a `ConversationRun`
- planning failure or approval rejection leaves an execution conversation plus draft evidence, but never a compatibility `AutomationRun`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/automation_execution_run_draft_flow_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/automation_failure_recovery_test.rb`

Historical red-phase expectation: FAIL because automation still routes through `AutomationPlanningService` and `AutomationRun`.

**Step 3: Write the minimal lifecycle implementation**

Implement:

- automation execution reuses `ConversationTurnOrchestrator`
- automation-specific trigger facts are stored in the new conversation and in draft/run snapshots
- `FinalizeService` only knows how to finalize a conversation-backed draft
- `ConversationRunTracker` only manages `ConversationRun`
- approval resume/expiry no longer sync back into `AutomationRun`

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/automation_execution_run_draft_flow_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/automation_failure_recovery_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/run_drafts app/models/conversation.rb app/models/conversation_run_tracker.rb test/integration/automation_execution_run_draft_flow_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/automation_failure_recovery_test.rb
git commit -m "refactor: route automation planning through conversation drafts"
```

### Task 4: Replace Automation Operator History With Execution-Conversation History

**Files:**
- Modify: `app/controllers/system/settings/automations_controller.rb`
- Delete: `app/controllers/system/settings/automation_runs_controller.rb`
- Create: `app/controllers/system/settings/automation_executions_controller.rb`
- Modify: `app/views/system/settings/automations/index.html.erb`
- Modify: `app/views/system/settings/automations/show.html.erb`
- Modify: routes for system settings automations
- Test: `test/integration/system_settings_automations_test.rb`
- Test: `test/system/system_settings_automations_test.rb`

**Step 1: Write the failing surface tests**

Cover:

- automation index shows latest execution conversation status, not latest `AutomationRun`
- automation detail shows execution conversations, derived draft/run status, and links into the execution conversation
- approve/reject actions target the parked draft for an execution conversation
- the UI no longer shows "Conversation binding", `AutomationRun` ids, or `conversation_run_id` as the primary history identity

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/system_settings_automations_test.rb`

Run: `bin/rails test:system test/system/system_settings_automations_test.rb`

Historical red-phase expectation: FAIL because controllers and views still load `automation_runs`.

**Step 3: Write the minimal surface implementation**

Implement:

- `AutomationsController` loads execution conversations and their latest draft/run projections
- nested actions resolve the parked draft by execution conversation
- UI columns become conversation instance, trigger time, derived status, approval state, and conversation link

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/system_settings_automations_test.rb`

Run: `bin/rails test:system test/system/system_settings_automations_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/controllers/system/settings app/views/system/settings/automations config/routes.rb test/integration/system_settings_automations_test.rb test/system/system_settings_automations_test.rb
git commit -m "refactor: show automation execution history by conversation"
```

### Task 5: Rewrite Product Docs And Supersede The Old Automation-Run Story

**Files:**
- Modify: `docs/product/automation.md`
- Modify: `docs/product/run_lifecycle.md`
- Modify: `docs/product/architecture.md`
- Modify: `docs/product/domain_model.md`
- Modify: `docs/product/execution_model.md`
- Modify: `docs/product/state_taxonomy.md`
- Modify: `docs/product/runtime_governance.md`
- Modify: `docs/product/README.md`
- Modify: `docs/product/migration_alignment.md`
- Modify: `docs/product/agent_rpc.md`
- Modify: `docs/product/programmable_agents.md`
- Modify: `docs/product/roadmap.md`

**Step 1: Write the failing documentation checklist**

Verify every doc states:

- `Automation` is definition only
- every automation trigger creates a new conversation
- `ConversationRun` is the only run
- `RunDraft` is planning-only state
- approval lives on draft, not run

**Step 2: Run the checklist against the current docs**

Run: `rg -n 'AutomationRun|optional conversation binding|automation-run|two immutable run records|owns its own lifecycle' docs/product`

Expected: MATCHES in the old docs.

**Step 3: Rewrite the docs**

Implement:

- remove `AutomationRun` from normative product docs
- describe automation execution history as conversation-backed
- describe approval as draft-backed
- explicitly note that old plan docs are superseded where necessary

**Step 4: Re-run the checklist**

Run: `rg -n 'AutomationRun|optional conversation binding|automation-run|two immutable run records|owns its own lifecycle' docs/product`

Expected: no matches that describe the old architecture as current truth

**Step 5: Commit**

```bash
git add docs/product
git commit -m "docs: converge automation and conversation runtime model"
```

### Task 6: Preserve The Recent Replay And `execution_capacity` Fixes While Running The Regression Sweep

**Files:**
- Review only: files touched by the replay fix and the `execution_capacity` naming cleanup
- Test: `test/models/agent_rpc_invocation_test.rb`
- Test: `test/integration/agent_rpc_invocation_replay_test.rb`
- Test: `test/integration/agent_rpc_activation_drift_test.rb`
- Test: `test/services/runtime_governance/execution_capacity_resolver_test.rb`
- Test: `test/services/runtime_governance/execution_capacity_enforcer_test.rb`
- Test: `test/services/runtime_governance/execution_capacity_leases_test.rb`
- Test: `test/integration/execution_capacity_enforcement_test.rb`

**Step 1: Run the targeted non-regression tests before the final sweep**

Run: `bin/rails test test/models/agent_rpc_invocation_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/agent_rpc_activation_drift_test.rb test/services/runtime_governance/execution_capacity_resolver_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/integration/execution_capacity_enforcement_test.rb`

Expected: PASS

**Step 2: Run the full automation/run-draft/conversation-run sweep**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/automation_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb test/services/automations/dispatch_test.rb test/jobs/automations/dispatch_due_job_test.rb test/integration/automation_execution_run_draft_flow_test.rb test/integration/automation_scheduler_flow_test.rb test/integration/automation_failure_recovery_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/system_settings_automations_test.rb`

Expected: PASS

**Step 3: Run the browser/operator sweep if system dependencies are available**

Run: `bin/rails test:system test/system/system_settings_automations_test.rb`

Expected: PASS

**Step 4: Inspect the diff for banned regressions**

Run: `git diff --stat`

Expected: no reintroduction of `AutomationRun`, no rollback from `execution_capacity`, no replay-binding drift.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: converge automation execution on conversations"
```

Plan complete and saved to `docs/plans/2026-03-10-automation-conversation-convergence.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**
