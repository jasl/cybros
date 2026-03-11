# Agent Deployment Connection Implementation Plan

**Goal:** implement the bounded programmable-agent runtime model around deployment lifecycle, conversation runtime selection, durable drafts, and replay-safe `agent_rpc`.

## Cross-Plan Dependencies

- `2026-03-08-runtime-governance.md` Task 1 owns executable schema for `ExecutionLocation`, `Workspace`, and `ExecutionTarget`.
- `2026-03-08-runtime-governance.md` Task 2 through Task 5 own governor resolution, waits, and admission primitives consumed during draft planning.
- `2026-03-10-automation-conversation-convergence.md` reuses the draft, run, and deployment semantics from this plan.

## Testing Posture

- schema work begins with model tests
- lifecycle work needs integration coverage
- transport and UI surfaces need targeted E2E coverage
- preflight failure paths are required, not optional polish

## Task 1: Add A Reference Programmable-Agent Fixture Harness

**Files:**

- create programmable-agent fixture server and helpers
- wire fixture lifecycle into CI and E2E harnesses

**Must cover:**

- deterministic fixture identity
- health responses
- `turn.prepare`
- `turn.compose`
- optional fixture startup for Playwright flows

**Verify with:**

`bin/rails test test/lib/cybros/programmable_agent_fixture_test.rb test/integration/ci_e2e_script_test.rb`

## Task 2: Add Core Runtime Schema For Programs, Deployments, Drafts, And RPC State

**Files:**

- add or replace schema for `agent_programs`
- create `agent_deployments`
- create `run_drafts`
- create `agent_rpc_sessions`
- create `agent_rpc_invocations`
- create `agent_rpc_operation_receipts`
- extend conversations and conversation runs for first-class runtime defaults and snapshots

**Must cover:**

- program-owned contract fingerprints and config namespace
- deployment-owned connectivity and inspection facts
- draft-owned staged mutations and prepared-plan persistence
- immutable run snapshots
- session, invocation, and operation-receipt runtime state

**Verify with:**

`bin/rails test test/models/agent_program_test.rb test/models/agent_deployment_test.rb test/models/run_draft_test.rb test/models/agent_rpc_session_test.rb test/models/agent_rpc_invocation_test.rb test/models/conversation_run_test.rb`

## Task 3: Implement Deployment Registration, Inspection, And Activation Gate

**Files:**

- registration services
- inspection services
- activation services
- operator-facing deployment settings surfaces

**Must cover:**

- explicit registration with operator-managed connection settings
- inspection through `initialize`, `agent.describe`, `agent.health`, and `agent.schemas.get`
- activation on exact protocol version, required methods, and healthy inspection result
- rejection on deployment identity mismatch

**Verify with:**

`bin/rails test test/integration/agent_deployments_registration_test.rb test/integration/agent_deployments_inspection_test.rb test/integration/agent_deployments_activation_gate_test.rb`

## Task 4: Implement Permission Presets And Conversation Agent Controls

**Files:**

- permission preset compiler
- conversation update surfaces
- composer agent and permission controls

**Must cover:**

- `conservative`, `default`, and `full_access`
- stable permission metadata with conservative fallback when a tool does not declare a permission class
- `Conversation.agent_program_id`
- `Conversation.permission_mode`
- stale warning when the selected program has no active healthy deployment
- config namespacing across agent switches

**Verify with:**

`bin/rails test test/lib/cybros/permissions/bundle_compiler_test.rb test/integration/conversation_permission_mode_test.rb test/integration/conversation_agent_program_selection_test.rb`

## Task 5: Implement Execution Target Inventory, Switch Policy, And Management Surfaces

**Files:**

- target inventory service
- target switch-policy service
- agent-facing target discovery handlers
- operator-facing target-management settings surfaces
- conversation target selector

**Must cover:**

- `execution_target.list`
- `execution_target.get`
- `execution_target.propose`
- one canonical switch-decision contract
- `Conversation.default_execution_target_id` as the single interactive target field
- same-target `allow`, visible-target `confirm` under conservative/default, validated auto-allow under `full_access`

**Verify with:**

`bin/rails test test/integration/execution_target_inventory_test.rb test/integration/run_draft_target_switch_policy_test.rb test/integration/conversation_default_execution_target_test.rb`

## Task 6: Implement Draft Planning, Finalization, And Approval Resume

**Files:**

- draft open/finalize/materialization services
- run-triggering orchestration
- staged public-mutation handling

**Must cover:**

- durable `RunDraft` before `turn.prepare`
- staged settings/config/KV mutation during planning
- finalization-time commit or discard
- approval park with persisted prepared result
- local approval resume with no second `turn.prepare`
- re-resolution after accepted target changes
- stale-draft failure instead of silent drift

**Verify with:**

`bin/rails test test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/run_draft_target_switch_test.rb`

## Task 7: Implement Session Auth, Replay, And Failure-Path Recovery

**Files:**

- session authorizer
- invocation store
- operation receipt store
- transport integration

**Must cover:**

- deployment bearer verification during `initialize`
- short-lived callback session bearer
- replay of the same `invocation_id` only against the same pinned binding
- `operation_id` de-duplication across replayed sessions
- lost reply recovery
- deployment drift and activation cutover handling

**Verify with:**

`bin/rails test test/integration/agent_rpc_session_auth_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/agent_rpc_lost_reply_recovery_test.rb test/integration/agent_rpc_activation_drift_test.rb`

## Task 8: Add End-To-End Coverage For Registration Through Invocation

**Files:**

- conversation runtime-selector E2E coverage
- deployment registration E2E coverage
- approval-resume E2E coverage
- target-switch E2E coverage
- session-auth and activation-drift E2E coverage

**Must cover:**

- register -> inspect -> activate -> select -> run
- approval park and resume
- stale deployment selection
- target-switch policy outcomes
- replay-safe callback behavior in the real flow

**Verify with:**

`bin/ci_e2e test/e2e/programmable_agent_registration.spec.ts test/e2e/programmable_agent_approval_resume.spec.ts test/e2e/programmable_agent_target_switch.spec.ts`
