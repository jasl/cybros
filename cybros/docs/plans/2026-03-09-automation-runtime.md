# Automation Runtime Implementation Plan

> Historical note (2026-03-10): this implementation plan was superseded by [`2026-03-10-automation-conversation-convergence.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-10-automation-conversation-convergence.md). It targeted a pre-convergence model with `AutomationRun` and optional conversation binding. Do not use this file as the current automation execution contract.

**Goal:** implement first-class automation dispatch, runtime semantics, and durable audit on top of the canonical programmable-agent lifecycle.

## Cross-Plan Dependencies

- `2026-03-09-agent-deployment-connection.md` owns drafts, deployment lifecycle, permission presets, and replay-safe `agent_rpc`.
- `2026-03-08-runtime-governance.md` owns governor resolution, admission, and waits.

Automation work should start only after those foundations exist.

## Testing Posture

- model and scheduler work needs model and integration tests
- dispatch and approval behavior need runtime integration coverage
- first user-reachable operator surfaces need browser coverage

## Task 1: Add Automation And Automation-Run Schema

**Files:**

- create or update automations and automation-runs schema
- add models and validations

**Must cover:**

- `agent_program_id`
- `execution_target_id`
- `permission_mode`
- optional `conversation_id`
- schedule or trigger fields
- immutable automation-run snapshot storage

**Verify with:**

`bin/rails test test/models/automation_test.rb test/models/automation_run_test.rb`

## Task 2: Implement Scheduler Dispatch And Idempotent Trigger Delivery

**Files:**

- scheduler dispatch services
- automation-run creation services
- trigger de-duplication or dispatch-key handling

**Must cover:**

- one trigger delivery becomes one automation dispatch
- retries do not create duplicate logical automation runs
- durable scheduling facts are captured before planning starts

**Verify with:**

`bin/rails test test/services/automations/dispatch_test.rb test/integration/automation_scheduler_flow_test.rb`

## Task 3: Route Automation Through RunDraft And Run Materialization

**Files:**

- automation-to-draft orchestration
- integration with run finalization and execution

**Must cover:**

- automation opens `RunDraft`
- automation resolves deployment and governors at execution time
- finalized automation dispatch snapshots deployment, target, permission preset, and schedule facts
- optional conversation binding produces the expected transcript linkage

**Verify with:**

`bin/rails test test/integration/automation_run_draft_flow_test.rb test/integration/automation_conversation_binding_test.rb`

## Task 4: Implement Manual Approval And Failure Semantics

**Files:**

- automation approval-state handling
- operator-visible manual-review surfaces or records
- failure-path integration tests

**Must cover:**

- default `full_access` path with no approval park
- explicit manual-approval parking when stricter presets require `confirm`
- rejection and retry semantics
- durable audit for parked, approved, rejected, failed, and completed automation runs

**Verify with:**

`bin/rails test test/integration/automation_manual_approval_test.rb test/integration/automation_failure_recovery_test.rb`

## Task 5: Add Operator Surfaces And End-To-End Coverage

**Files:**

- operator-visible automation and automation-run surfaces
- targeted E2E coverage for scheduled dispatch and manual review

**Must cover:**

- visibility into current automation bindings
- visibility into run history and status
- one end-to-end scheduled dispatch flow
- one end-to-end manual-approval flow

**Verify with:**

`bin/rails test test/integration/system_settings_automations_test.rb`
