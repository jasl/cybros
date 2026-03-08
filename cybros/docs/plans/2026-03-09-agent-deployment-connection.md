# Agent Deployment Connection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the approved programmable-agent runtime model around deployment registration, permission presets, target discovery, durable drafts, immutable runs, and replay-safe agent RPC.

**Architecture:** Keep `RunDraft` as the mutable planning object and `ConversationRun` as the immutable execution snapshot. Treat `AgentDeployment` as the only connectable runtime unit, expose execution-target discovery as formal public APIs, and reuse shared `allow` / `confirm` / `deny` policy semantics for target switching instead of inventing a parallel approval contract. Conversation- and automation-scoped permission presets should compile into Cybros-owned runtime policy bundles instead of becoming a second approval system.

**Tech Stack:** Ruby on Rails, PostgreSQL, AgentCore/DAG, WebSocket or stdio agent RPC adapters, Playwright

---

## Canonical References

- `docs/plans/2026-03-09-execution-target-discovery-design.md`
- `docs/plans/2026-03-09-permission-presets-design.md`
- `docs/plans/2026-03-09-agent-deployment-connection-design.md`
- `docs/plans/2026-03-09-programmable-agent-preflight-design.md`
- `docs/product/domain_model.md`
- `docs/product/execution_model.md`
- `docs/product/agent_rpc.md`
- `docs/plans/2026-03-08-phase-1-schema-cut-list.md`

## Cross-Plan Dependencies

- `docs/plans/2026-03-08-runtime-governance.md` Task 3 owns the `ExecutionLocation`, `Workspace`, and `ExecutionTarget` schema surfaces used by target discovery and target-switch policy resolution, including explicit policy fields, tag arrays, capability-tag arrays, and execution-quota fields.
- `docs/plans/2026-03-08-runtime-governance.md` Task 4 owns runtime-governor resolution after an accepted target switch changes the effective execution target.
- `docs/plans/2026-03-08-runtime-governance.md` Task 7 owns the operator-facing execution-location and workspace settings surfaces consumed by execution-target management.
- This plan owns the programmable-agent-facing permission preset compiler, composer agent and target selectors, conversation permissions UI, target discovery APIs, target-switch policy wiring, operator settings surfaces for targets and deployments, draft approval behavior, and E2E coverage for conversation runtime selection.

**Destructive Reset Rule:** This plan assumes the programmable-agent rebaseline can reset the database. Prefer editing first-cut create migrations and regenerating `db/schema.rb` over keeping compatibility columns, fallback associations, or transitional runtime tables.

**Execution Sequence Note:** For a straight-through implementation run, Task 1 through Task 3 here may land first. Task 4 should wait for `docs/plans/2026-03-08-runtime-governance.md` Task 3 and Task 7, because target discovery and target-management settings consume the execution-location, workspace, and target schema plus their operator-facing source surfaces. Task 5 should wait for `docs/plans/2026-03-08-runtime-governance.md` Task 4, because draft re-resolution depends on resolved-governor facts.

## Testing Posture

Every behavior-changing task in this plan should name exact verification files and commands.

- schema and model work should start with failing model tests
- orchestration work should add integration coverage for the real draft and RPC path
- browser flows should run through `bin/ci_e2e`, not manual environment bootstrapping
- preflight failure paths are not optional; each required failure mode must map to at least one concrete test file before this plan is considered architecture-complete

## Task 1: Add A Reference Programmable-Agent Fixture Harness

**Files:**
- Create: `test/support/programmable_agent_fixture.rb`
- Create: `test/support/programmable_agent_fixture_server.rb`
- Modify: `bin/ci_e2e`
- Modify: `test/integration/ci_e2e_script_test.rb`
- Create: `test/e2e/helpers/programmable_agent.ts`
- Test: `test/lib/cybros/programmable_agent_fixture_test.rb`
- Test: `test/integration/ci_e2e_script_test.rb`

**Step 1: Write the failing tests**

Cover:

- starting a fixture deployment from test code
- deterministic fixture identity and health responses
- `bin/ci_e2e` optionally starting and stopping the fixture deployment
- fixture readiness before Playwright begins

**Step 2: Run the targeted tests**

Run: `bin/rails test test/lib/cybros/programmable_agent_fixture_test.rb test/integration/ci_e2e_script_test.rb`
Expected: failures due to the missing programmable-agent fixture harness.

**Step 3: Implement the minimal harness**

Provide one reusable reference deployment that can answer `initialize`, `agent.describe`, `agent.health`, `turn.prepare`, and `turn.compose` for integration and E2E coverage.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/lib/cybros/programmable_agent_fixture_test.rb test/integration/ci_e2e_script_test.rb`
Expected: PASS.

## Task 2: Add The Deployment, Draft, And RPC Runtime Schema

**Files:**
- Create: `db/migrate/*_create_run_drafts.rb`
- Create: `db/migrate/*_create_agent_deployments.rb`
- Create: `db/migrate/*_create_agent_rpc_sessions.rb`
- Create: `db/migrate/*_create_agent_rpc_invocations.rb`
- Create: `db/migrate/*_create_agent_rpc_operation_receipts.rb`
- Modify: `db/migrate/*_create_agent_programs.rb`
- Modify: `db/migrate/*_create_conversations.rb`
- Modify: `db/migrate/*_create_conversation_runs.rb`
- Modify: `db/migrate/*_create_automations.rb`
- Modify: `db/migrate/*_create_automation_runs.rb`
- Modify: `app/models/agent_program.rb`
- Modify or create: `app/models/conversation.rb`
- Modify or create: `app/models/automation.rb`
- Create: `app/models/run_draft.rb`
- Create: `app/models/agent_deployment.rb`
- Create: `app/models/agent_rpc_session.rb`
- Create: `app/models/agent_rpc_invocation.rb`
- Create: `app/models/agent_rpc_operation_receipt.rb`
- Modify: `app/models/conversation_run.rb`
- Modify: `db/schema.rb`
- Test: `test/models/conversation_permission_mode_test.rb`
- Test: `test/models/automation_permission_mode_test.rb`
- Test: `test/models/agent_program_test.rb`
- Test: `test/models/run_draft_test.rb`
- Test: `test/models/agent_deployment_test.rb`
- Test: `test/models/agent_rpc_session_test.rb`
- Test: `test/models/agent_rpc_invocation_test.rb`
- Test: `test/models/conversation_run_test.rb`

**Step 1: Write the failing tests**

Cover:

- `AgentProgram` stores manifest snapshot, stable config namespace, config schemas, and `config_schema_fingerprint`
- `Conversation.agent_program_id` persists the selected top-level agent program
- `Conversation.permission_mode` persists one of `conservative`, `default`, or `full_access`
- `Automation.permission_mode` defaults to `full_access`
- `RunDraft` carries `initiated_by_user_id`, `prepare_invocation_id`, `prepared_plan`, staged public mutations, pinned deployment facts, and `permission_mode`
- `ConversationRun` snapshots `agent_program_id`, deployment fingerprint, activation epoch, public settings, `agent_config`, runtime governor facts, and `effective_permission_mode`
- `AgentRpcSession` stores `session_token_digest`, allowed methods, expiry, and a link to the logical invocation
- `AgentRpcInvocation` uniqueness includes deployment fingerprint plus activation epoch
- `AgentDeployment` stores deployment bearer reference and inspection facts

**Step 2: Run the targeted tests**

Run: `bin/rails test test/models/agent_program_test.rb test/models/conversation_permission_mode_test.rb test/models/automation_permission_mode_test.rb test/models/run_draft_test.rb test/models/agent_deployment_test.rb test/models/agent_rpc_session_test.rb test/models/agent_rpc_invocation_test.rb test/models/conversation_run_test.rb`
Expected: failures due to missing schema or model definitions.

**Step 3: Implement the minimal schema and model layer**

Keep v1 single-tenant, use explicit user actor fields only where they carry business meaning, and keep runtime tables global unless they are directly user-owned.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/models/agent_program_test.rb test/models/conversation_permission_mode_test.rb test/models/automation_permission_mode_test.rb test/models/run_draft_test.rb test/models/agent_deployment_test.rb test/models/agent_rpc_session_test.rb test/models/agent_rpc_invocation_test.rb test/models/conversation_run_test.rb`
Expected: PASS.

## Task 3: Implement Permission Presets And Composer Agent Controls

**Files:**
- Create: `lib/cybros/permissions/preset.rb`
- Create: `lib/cybros/permissions/bundle_compiler.rb`
- Modify: `lib/cybros/agent_runtime_resolver.rb`
- Modify: `app/controllers/conversations_controller.rb`
- Modify: `app/views/conversations/show.html.erb`
- Modify: `config/routes.rb`
- Test: `test/lib/cybros/permissions/bundle_compiler_test.rb`
- Test: `test/integration/conversation_permission_mode_test.rb`
- Test: `test/integration/conversation_agent_program_selection_test.rb`
- Test: `test/e2e/conversation_permission_mode.spec.ts`
- Test: `test/e2e/conversation_agent_program.spec.ts`

**Step 1: Write the failing tests**

Cover:

- `conservative`, `default`, and `full_access` compile into distinct runtime policy bundles
- unknown or missing preset values fall back safely
- the composer footer shows the current conversation agent and permission preset next to model selection
- switching the conversation agent persists `Conversation.agent_program_id` at the conversation level instead of only affecting one message
- switching the conversation agent affects future drafts and runs only, not an already materialized run
- selecting an agent with no active healthy deployment surfaces a stale warning and blocks new draft materialization until fixed or reselected
- switching the preset persists at the conversation level instead of only affecting one message
- switching the conversation agent does not clear unrelated namespaced `agent_config` data
- subagents remain owned by the currently active top-level agent for that turn and are not retroactively redirected by later conversation agent changes
- `Automation` defaults continue to resolve to `full_access`

**Step 2: Run the targeted tests**

Run: `bin/rails test test/lib/cybros/permissions/bundle_compiler_test.rb test/integration/conversation_permission_mode_test.rb test/integration/conversation_agent_program_selection_test.rb`
Expected: failures due to the missing preset compiler or conversation update surface.

Run: `bin/ci_e2e test/e2e/conversation_permission_mode.spec.ts test/e2e/conversation_agent_program.spec.ts`
Expected: FAIL because the composer runtime selectors are not yet wired.

**Step 3: Implement the minimal preset and UI layer**

Compile conversation- and automation-scoped permission presets into Cybros-owned policy bundles, and expose the conversation agent selector as a first-class runtime-default control. Do not reintroduce metadata-driven policy state or a second approval system.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/lib/cybros/permissions/bundle_compiler_test.rb test/integration/conversation_permission_mode_test.rb test/integration/conversation_agent_program_selection_test.rb`
Expected: PASS.

Run: `bin/ci_e2e test/e2e/conversation_permission_mode.spec.ts test/e2e/conversation_agent_program.spec.ts`
Expected: PASS.

## Task 4: Implement Execution Target Inventory, Switch Policy, And Management Surfaces

**Files:**
- Create: `app/services/execution_targets/inventory.rb`
- Create: `app/services/execution_targets/switch_policy.rb`
- Create: `app/controllers/system/settings/execution_targets_controller.rb`
- Create: `app/views/system/settings/execution_targets/index.html.erb`
- Create: `app/views/system/settings/execution_targets/new.html.erb`
- Create: `app/views/system/settings/execution_targets/edit.html.erb`
- Create: `app/views/system/settings/execution_targets/_form.html.erb`
- Modify: `app/controllers/conversations_controller.rb`
- Modify: `app/views/conversations/show.html.erb`
- Modify: `config/routes.rb`
- Modify: agent RPC public-API handlers under `app/services` or `lib/agent_core`
- Test: `test/integration/execution_target_inventory_test.rb`
- Test: `test/integration/run_draft_target_switch_policy_test.rb`
- Test: `test/integration/system_settings_execution_targets_test.rb`
- Test: `test/integration/conversation_default_execution_target_test.rb`
- Test: `test/e2e/conversation_execution_target.spec.ts`

**Step 1: Write the failing tests**

Cover:

- visible target inventory through `execution_target.list`
- target detail through `execution_target.get`
- `switch_decision_preview` using shared `allow` / `confirm` / `deny` semantics
- default `confirm` for switching to a different visible target under `conservative` and `default`
- `full_access` allowing a validated visible target switch without an approval park
- policy override allowing auto-switch inside trusted boundaries
- rejection for invisible, inactive, or unhealthy targets
- the composer footer shows and persists `Conversation.default_execution_target_id`
- the composer target selector only affects future drafts or runs
- accepted target proposals finalize back into the same canonical conversation field
- system settings expose CRUD-style management for execution targets with location/workspace selection and sandboxed posture

**Step 2: Run the targeted tests**

Run: `bin/rails test test/integration/execution_target_inventory_test.rb test/integration/run_draft_target_switch_policy_test.rb test/integration/system_settings_execution_targets_test.rb test/integration/conversation_default_execution_target_test.rb`
Expected: failures due to missing target discovery APIs and switch-policy behavior.

Run: `bin/ci_e2e test/e2e/conversation_execution_target.spec.ts`
Expected: FAIL because the conversation target selector is not yet wired.

**Step 3: Implement the minimal discovery and policy layer**

Keep discovery, policy, and hard runtime validation separate. Reuse the shared decision vocabulary instead of inventing a target-specific approval contract. Use `Conversation.default_execution_target_id` as the only canonical interactive target field.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/integration/execution_target_inventory_test.rb test/integration/run_draft_target_switch_policy_test.rb test/integration/system_settings_execution_targets_test.rb test/integration/conversation_default_execution_target_test.rb`
Expected: PASS.

Run: `bin/ci_e2e test/e2e/conversation_execution_target.spec.ts`
Expected: PASS.

## Task 5: Implement Draft Planning, Finalization, And Approval Resume

**Files:**
- Create: `app/services/run_drafts/open.rb`
- Create: `app/services/run_drafts/finalize.rb`
- Create: `app/services/run_drafts/materialize_conversation_run.rb`
- Create: `app/services/run_drafts/approval_resume.rb`
- Modify: `lib/cybros/agent_runtime_resolver.rb`
- Modify: run-triggering orchestration code under `app/services` or `lib/agent_core`
- Test: `test/integration/run_draft_finalization_test.rb`
- Test: `test/integration/run_draft_approval_resume_test.rb`
- Test: `test/integration/run_draft_target_switch_test.rb`

**Step 1: Write the failing tests**

Cover:

- opening a durable `RunDraft` before `turn.prepare`
- snapshotting the conversation or automation permission preset onto the draft before planning
- snapshotting the conversation's selected `agent_program_id` onto the draft before planning
- staging public settings/config/KV mutations on the draft during planning
- committing or discarding staged draft mutations only during finalization
- approval park persisting the prepared plan and ending the current planning session
- approval resume continuing local finalization without a second `turn.prepare`
- re-resolving deployment, provider, and governor facts after target changes
- applying `execution_target.propose` results without collapsing discovery reads into draft mutation
- materializing `ConversationRun.effective_permission_mode` and compiled policy summary from the finalized draft
- denied target-switch confirmation rejecting the draft instead of silently continuing with the old target-dependent plan

**Step 2: Run the targeted tests**

Run: `bin/rails test test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/run_draft_target_switch_test.rb`
Expected: failures due to missing draft orchestration and approval-resume behavior.

**Step 3: Implement the minimal draft orchestration**

Keep planning and finalization separate. Do not mutate a materialized `ConversationRun` in place to represent approval waits or target-switch planning.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/run_draft_target_switch_test.rb`
Expected: PASS.

## Task 6: Implement Deployment Registration, Inspection, And Activation Gate

**Files:**
- Create: `app/services/agent_deployments/register.rb`
- Create: `app/services/agent_deployments/inspect.rb`
- Create: `app/services/agent_deployments/activate.rb`
- Create: `app/controllers/system/settings/agent_deployments_controller.rb`
- Create: `app/views/system/settings/agent_deployments/index.html.erb`
- Create: `app/views/system/settings/agent_deployments/new.html.erb`
- Create: `app/views/system/settings/agent_deployments/show.html.erb`
- Create: `app/views/system/settings/agent_deployments/_form.html.erb`
- Modify: operator-facing deployment registration controllers or endpoints under `app/controllers`
- Test: `test/integration/agent_deployments_registration_test.rb`
- Test: `test/integration/agent_deployments_inspection_test.rb`
- Test: `test/integration/agent_deployments_activation_gate_test.rb`
- Test: `test/integration/system_settings_agent_deployments_test.rb`

**Step 1: Write the failing tests**

Cover:

- explicit deployment registration with operator-managed connection settings
- inspection through `initialize`, `agent.describe`, `agent.health`, and `agent.schemas.get`
- activation only on exact v1 protocol version, required methods, and healthy inspection result
- rejection on mismatched deployment identity claims during `initialize`
- rejection on unhealthy deployment or missing required methods
- system settings expose deployment registration, inspection visibility, activation state, and health status

**Step 2: Run the targeted tests**

Run: `bin/rails test test/integration/agent_deployments_registration_test.rb test/integration/agent_deployments_inspection_test.rb test/integration/agent_deployments_activation_gate_test.rb test/integration/system_settings_agent_deployments_test.rb`
Expected: failures due to missing registration and activation flow.

**Step 3: Implement the minimal deployment lifecycle**

Persist normalized inspection facts for audit and debugging, but do not build compatibility routing or supervisor behavior in v1.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/integration/agent_deployments_registration_test.rb test/integration/agent_deployments_inspection_test.rb test/integration/agent_deployments_activation_gate_test.rb test/integration/system_settings_agent_deployments_test.rb`
Expected: PASS.

## Task 7: Implement Session Auth, Invocation Replay, And Failure-Path Recovery

**Files:**
- Create: `app/services/agent_rpc/session_authorizer.rb`
- Create: `app/services/agent_rpc/invocation_store.rb`
- Create: `app/services/agent_rpc/operation_receipts.rb`
- Modify: agent RPC transport/session code under `lib/agent_core` and `app/services`
- Test: `test/integration/agent_rpc_session_auth_test.rb`
- Test: `test/integration/agent_rpc_invocation_replay_test.rb`
- Test: `test/integration/agent_rpc_lost_reply_recovery_test.rb`
- Test: `test/integration/agent_rpc_activation_drift_test.rb`

**Step 1: Write the failing tests**

Cover:

- deployment bearer presented by Cybros and verified during `initialize`
- short-lived session bearer auth for callbacks within one bounded session
- callback rejection when the session is expired, out of scope, or uses an invalid bearer
- replay of the same `invocation_id` against the same pinned deployment binding
- callback `operation_id` de-duplication across session replay
- lost reply after remote execution begins
- deployment fingerprint drift between inspection and invocation
- deployment activation cutover while a draft is parked

**Step 2: Run the targeted tests**

Run: `bin/rails test test/integration/agent_rpc_session_auth_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/agent_rpc_lost_reply_recovery_test.rb test/integration/agent_rpc_activation_drift_test.rb`
Expected: failures due to missing session auth, replay bookkeeping, or drift handling.

**Step 3: Implement the minimal replay-safe RPC runtime**

Keep sessions, invocations, and operation receipts as separate runtime-state artifacts. Approval resume should continue locally from the persisted prepared draft and must not reopen planning.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/integration/agent_rpc_session_auth_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/agent_rpc_lost_reply_recovery_test.rb test/integration/agent_rpc_activation_drift_test.rb`
Expected: PASS.

## Task 8: Add E2E Coverage For Registration Through Invocation

**Files:**
- Create: `test/e2e/conversation_permission_mode.spec.ts`
- Create: `test/e2e/conversation_agent_program.spec.ts`
- Create: `test/e2e/conversation_execution_target.spec.ts`
- Create: `test/e2e/programmable_agent_registration.spec.ts`
- Create: `test/e2e/programmable_agent_approval_resume.spec.ts`
- Create: `test/e2e/programmable_agent_session_auth.spec.ts`
- Create: `test/e2e/programmable_agent_activation_drift.spec.ts`
- Create: `test/e2e/programmable_agent_target_switch.spec.ts`
- Modify: `test/e2e/helpers.ts`

**Step 1: Write the failing specs**

Cover:

- selecting and persisting the conversation agent in the composer footer
- selecting and persisting the conversation permission preset in the composer footer
- selecting and persisting the conversation execution target in the composer footer
- external start of the reference deployment and explicit registration in Cybros
- inspection and healthcheck before activation
- selecting the conversation's agent program after its deployment has been registered and activated
- a real turn through `turn.prepare` and `turn.compose`
- visible execution-target inventory through the programmable-agent public API boundary
- target switching defaulting to `confirm` and using policy override when configured
- approval park and resume without a second `turn.prepare`
- expired or invalid session bearer rejection
- activation drift or identity mismatch surfaced as a structured failure

**Step 2: Run the targeted specs**

Run: `bin/ci_e2e test/e2e/conversation_permission_mode.spec.ts test/e2e/conversation_agent_program.spec.ts test/e2e/conversation_execution_target.spec.ts test/e2e/programmable_agent_registration.spec.ts test/e2e/programmable_agent_target_switch.spec.ts test/e2e/programmable_agent_approval_resume.spec.ts test/e2e/programmable_agent_session_auth.spec.ts test/e2e/programmable_agent_activation_drift.spec.ts`
Expected: FAIL because the programmable-agent path is not yet fully wired.

**Step 3: Implement the minimal end-to-end path**

Keep this path deployment-first and auditable. The reference fixture should be enough to validate the public API boundary without hidden manual setup.

**Step 4: Re-run the targeted specs**

Run: `bin/ci_e2e test/e2e/conversation_permission_mode.spec.ts test/e2e/conversation_agent_program.spec.ts test/e2e/conversation_execution_target.spec.ts test/e2e/programmable_agent_registration.spec.ts test/e2e/programmable_agent_target_switch.spec.ts test/e2e/programmable_agent_approval_resume.spec.ts test/e2e/programmable_agent_session_auth.spec.ts test/e2e/programmable_agent_activation_drift.spec.ts`
Expected: PASS.

## Preflight Coverage Map

The required failure paths from `2026-03-09-programmable-agent-preflight-design.md` should map to these tests:

- repeated `turn.prepare` delivery with the same `invocation_id` after transport retry or lost reply:
  `test/integration/agent_rpc_invocation_replay_test.rb`
- approval resume with no second `turn.prepare` call for the same prepared draft:
  `test/integration/run_draft_approval_resume_test.rb`
  `test/e2e/programmable_agent_approval_resume.spec.ts`
- conversation-scoped agent selection persistence and composer control:
  `test/integration/conversation_agent_program_selection_test.rb`
  `test/e2e/conversation_agent_program.spec.ts`
- conversation-scoped permission preset persistence and composer control:
  `test/integration/conversation_permission_mode_test.rb`
  `test/e2e/conversation_permission_mode.spec.ts`
- conversation-scoped execution-target persistence and composer control:
  `test/integration/conversation_default_execution_target_test.rb`
  `test/e2e/conversation_execution_target.spec.ts`
- target discovery through public APIs and confirm-by-default target-switch behavior:
  `test/integration/execution_target_inventory_test.rb`
  `test/integration/run_draft_target_switch_policy_test.rb`
  `test/e2e/programmable_agent_target_switch.spec.ts`
- lost reply after remote execution begins:
  `test/integration/agent_rpc_lost_reply_recovery_test.rb`
- deployment fingerprint drift between inspection and invocation:
  `test/integration/agent_rpc_activation_drift_test.rb`
- deployment activation cutover while a draft is parked:
  `test/integration/agent_rpc_activation_drift_test.rb`
- expired or invalid callback session scope rejection:
  `test/integration/agent_rpc_session_auth_test.rb`

## Acceptance

- active product docs all describe the same deployment-centric model
- no active doc assumes `AgentHost` as a v1 canonical model
- `agent_config` remains opaque JSON in v1
- `AgentProgram` owns a stable config namespace and config-contract snapshot for conversation-scoped agent configuration
- `Conversation.agent_program_id` is the canonical interactive top-level agent field and is updated by the composer agent selector for future turns only
- `agent_config` remains namespaced conversation storage and is not cleared wholesale when the conversation switches top-level agents
- conversation-level agent selection only changes the top-level agent for future turns and does not retroactively redirect subagents launched by an earlier turn
- production transport direction is network-first
- conversation and automation permission presets are explicit schema fields instead of metadata-driven policy state
- the composer permissions control persists to `Conversation` and affects future drafts instead of only the current message submission
- `Conversation.default_execution_target_id` is the canonical interactive target field and is updated by both the composer target selector and accepted agent target proposals
- execution-target discovery is formalized through public APIs instead of prompt-only conventions
- target-switch policy reuses shared `allow` / `confirm` / `deny` semantics and honors the active permission preset
- execution targets and agent deployments are operator-manageable through settings surfaces instead of being runtime-only internals
- the runtime reset remains destructive; deployment, draft, and RPC schema work does not preserve legacy compatibility shims
- draft-time public mutations are staged until finalization
- approval resume does not reopen planning for the same prepared draft
- bounded sessions, logical invocations, and callback receipts are modeled separately
- lightweight deployment/session bearer auth is defined and tested for v1
- required preflight failure paths are mapped to concrete integration or E2E coverage
- the registration -> inspection -> activation -> planning -> execution path can be verified with targeted commands and `bin/ci_e2e`
