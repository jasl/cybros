# Cybros Main App Cleanup Ledger

## Active Truth Sources

Current cleanup/process truth sources:

- `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-design.md`
- `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup.md`

Current product/runtime truth sources to preserve as active:

- `cybros/docs/README.md`
- `cybros/docs/dag/public_api.md`
- `cybros/docs/dag/workflow_engine.md`
- `cybros/docs/agent_core/public_api.md`
- `cybros/docs/plans/2026-03-13-conversation-agent-runtime-simplification-design.md`
- `cybros/docs/plans/2026-03-16-agent-root-workspace.md`
- `cybros/docs/plans/2026-03-17-operation-sequence-cutover.md`

Current code ownership anchors:

- `cybros/app/models/conversation.rb`
- `cybros/app/services/conversations/attachment_transfer_service.rb`
- `cybros/app/services/agents/creator.rb`
- `cybros/app/services/agent_rpc/session_authorizer.rb`
- `cybros/test/test_helper.rb`

Old nouns/removal targets for this cleanup:

- `agent_program_key`
- `agent_program:` fixture/setup arguments
- `default_execution_target`
- `execution_target:` fixture/setup arguments where `Agent` is the real live boundary
- active plan docs that still assign live meaning to `ExecutionLocation`, `ExecutionTarget`, or `AgentDeployment`

## P0 Live-Path Findings

1. `agent_program_key` fallback is still live in production code.
   Evidence:
   - `cybros/app/services/agents/creator.rb:11`
   - `cybros/app/services/agents/creator.rb:71`
   - `cybros/app/services/agent_rpc/session_authorizer.rb:224`
   - `cybros/app/services/agent_rpc/session_authorizer.rb:228`
   - `cybros/app/services/agent_rpc/session_authorizer.rb:231`
   Action: `delete`
   Notes: Removed in Round 3. Live `app/`, `lib/`, and `config/` now have zero `agent_program_key` hits; remaining hits are test/data cleanup plus explicit negative coverage.

2. Active plans still expose old runtime truth as if it were current.
   Evidence:
   - `cybros/docs/plans/2026-03-08-runtime-governance-design.md:25`
   - `cybros/docs/plans/2026-03-08-runtime-governance.md:9`
   - `cybros/docs/plans/2026-03-09-agent-deployment-connection-design.md:17`
   - `cybros/docs/plans/2026-03-09-automation-runtime-design.md:3`
   - `cybros/docs/plans/2026-03-09-execution-target-discovery-design.md:107`
   - `cybros/docs/plans/2026-03-09-automation-runtime.md:29`
   Action: `archive`
   Notes: These are historical planning materials, so they should move under `docs/archive` rather than remain in the active plans tree.

3. Active docs still document future cleanup work as not-yet-done even where current app truth has already moved.
   Evidence:
   - `cybros/docs/plans/2026-03-16-agent-root-workspace.md:80`
   - `cybros/docs/plans/2026-03-17-operation-sequence-cutover.md:391`
   - `cybros/docs/plans/2026-03-17-operation-sequence-cutover.md:402`
   Action: `keep` for now
   Notes: These are active design lineage, not immediately misleading product docs, but they are part of the truth-source set that later rounds must re-check against code.

## P1 Test/Helper Findings

1. `agent_program_key` fixture payloads remain widespread in tests.
   Evidence:
   - `cybros/test/lib/test_support/bundled_claw_runtime_server_test.rb:26`
   - `cybros/test/services/agents/bootstrap_bundled_default_service_test.rb:74`
   - `cybros/test/services/agent_rpc/lifecycle_caller_test.rb:113`
   - `cybros/test/integration/agent_rpc_session_auth_test.rb:286`
   - `cybros/test/integration/programmable_agent_execution_test.rb:244`
   - `cybros/lib/cybros/programmable_agent_fixture.rb:14`
   Action: `delete`
   Notes: This is the first broad test/data cleanup cluster after the live fallback is removed.
   Batch A (Task 4): `run_draft_test`, `conversation_run_test`, `lifecycle_caller_test`, `agent_runtime_binding_cutover_test`, `agent_rpc_runtime_state_cutover_test`, `programmable_agent_execution_test`, `conversations_test`, `programmable_agent_step_status_placeholder_test`.
   Batch B (Task 4): `agent_runtime_resolver_llm_provider_test`, `programmable_agent/tool_execution_test`, `programmable_agent/recognized_deployment_resolver_test`, `programmable_agent_provider_test`, `programmable_agent/hook_action_executor_test`, `agent_core/dag/runtime_surface_error_handling_test`, `agent_core/dag/agent_output_finalization_test`, `agent_core/dag/task_executor_runtime_surface_test`.
   Batch C (Task 4): `agent_upgrade_conversation_binding_test`, `agent_rpc_lost_reply_recovery_test`, `agent_rpc_activation_drift_test`, `programmable_agent_capabilities_refresh_test`, `programmable_agent_hooks_test`, `programmable_agent_execution_context_test`, `agent_rpc_invocation_replay_test`, `bootstrap_hook_contract_test`.
   Batch D (Task 4): `jobs/automations/execute_conversation_job_test`, `integration/system_settings_automations_test`, `integration/automation_failure_recovery_test`, `integration/automation_execution_conversation_test`, `integration/automation_execution_run_draft_flow_test`, `integration/automation_manual_approval_test`, `integration/run_draft_finalization_test`, `integration/run_draft_approval_resume_test`.
   Batch E (Task 4): `dashboard_test`, `conversation_bootstrap_dispatch_test`, `programmable_agent_tool_routing_test`, `agent_execution_capacity_test`, `programmable_agent_capabilities_handshake_test`, `recognized_deployment_drift_test`.
   Batch F (Task 4, unverified in this environment): `test/system/system_settings_automations_test.rb`, `test/script/live_acceptance/agent_root_workspace_test.rb`.

2. `test/test_helper.rb` still exposes obsolete conversation/runtime helper arguments.
   Evidence:
   - `cybros/test/test_helper.rb:233`
   - `cybros/test/test_helper.rb:420`
   - `cybros/test/test_helper.rb:439`
   - `cybros/test/test_helper.rb:546`
   - `cybros/test/test_helper.rb:783`
   Action: `delete` / `Rails-shaped simplify`
   Notes: This is the main source of test truth pollution.
   Batch A (Task 5): `agent_test`, `run_draft_test`, `conversation_run_test`, `recognized_deployment_test`, `lifecycle_caller_test`, `agent_rpc_lost_reply_recovery_test`, `execution_capacity_enforcement_test`, `agent_runtime_binding_cutover_test`, `run_draft_finalization_test`, `run_draft_approval_resume_test`.

3. Tests still build the world through `agent_program:` and `default_execution_target:` even when runtime state is agent-owned now.
   Evidence:
   - `cybros/test/models/run_draft_test.rb:140`
   - `cybros/test/models/conversation_run_test.rb:21`
   - `cybros/test/models/recognized_deployment_test.rb:82`
   - `cybros/test/integration/agent_runtime_binding_cutover_test.rb:32`
   - `cybros/test/integration/external_agent_attachment_transfer_test.rb:31`
   Action: `delete`
   Notes: This cluster will need explicit batching because it is broad.
   Round 5 update: the first helper-contract batch is now clean and verified; remaining hits cluster in automation flows, runtime-governance tests, attachment/invocation integration tests, and a small set of system/live-acceptance files.

4. Runtime governance and automation tests still model capacity through synthetic execution-target profiles.
   Evidence:
   - `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb:25`
   - `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb:7`
   - `cybros/test/integration/runtime_governance_observability_test.rb:214`
   - `cybros/test/services/automations/dispatch_test.rb:127`
   - `cybros/test/jobs/automations/execute_conversation_job_test.rb:83`
   Action: `delete` / `Rails-shaped simplify`
   Notes: This is Task 6's main cluster.
   Round 6 update: the selected runtime-governance and automation suites are now agent-centric and verified; remaining `execution_target` residue is concentrated in adjacent system/runtime-governance surfaces, RPC/runtime fixture tests, and tool/attachment/runtime-surface tests.

## P2 Rails-Shaped Simplify Findings

1. Conversation workspace ownership is split between model and a thin wrapper service.
   Evidence:
   - `cybros/app/models/conversation.rb:287`
   - `cybros/app/models/conversation.rb:295`
   - `cybros/app/services/conversations/workspace_initializer.rb:1`
   Action: `Rails-shaped simplify`
   Notes: Candidate for the first explicit P2 batch once P0/P1 are under control.

2. Test runtime fixture APIs still model the removed infrastructure layer instead of the live `Agent` boundary.
   Evidence:
   - `cybros/test/test_helper.rb:372`
   - `cybros/test/test_helper.rb:389`
   - `cybros/test/test_helper.rb:403`
   Action: `Rails-shaped simplify`
   Notes: This is coupled to Task 6.

## Archive Candidates

- `cybros/docs/plans/2026-03-08-runtime-governance-design.md` -> `archive`
- `cybros/docs/plans/2026-03-08-runtime-governance.md` -> `archive`
- `cybros/docs/plans/2026-03-09-agent-deployment-connection-design.md` -> `archive`
- `cybros/docs/plans/2026-03-09-automation-runtime-design.md` -> `archive`
- `cybros/docs/plans/2026-03-09-automation-runtime.md` -> `archive`
- `cybros/docs/plans/2026-03-09-execution-target-discovery-design.md` -> `archive`
- `cybros/docs/plans/2026-03-09-runtime-governance-operator-surfaces.md` -> `archive`

## Delete Candidates

- live `legacy_manifest_agent_key` fallback in:
  - `cybros/app/services/agents/creator.rb`
  - `cybros/app/services/agent_rpc/session_authorizer.rb`
- stale helper args in:
  - `cybros/test/test_helper.rb`
- broad test fixture residue using:
  - `agent_program_key`
  - `agent_program:`
  - `default_execution_target`
  - `execution_target:`

## Keep-With-Reason Candidates

1. Generic `fallback` terminology outside runtime compatibility cleanup.
   Evidence:
   - `cybros/app/channels/conversation_channel.rb`
   - `cybros/lib/agent_core/runtime_surface/runner.rb`
   - `cybros/config/application.rb`
   Reason: these hits are about real fallback behavior, not stale architecture.

2. `agent_profile` in active docs and subagent flows.
   Evidence:
   - `cybros/docs/agent_core/public_api.md`
   - `cybros/docs/agent_core/security.md`
   Reason: still part of the current subagent/configuration model; not an obsolete top-level runtime noun by itself.

3. Untracked report file outside the approved cleanup scope.
   Evidence:
   - `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md` (`git status --short` shows it untracked)
   Reason: do not let an unrelated untracked document distort tracked cleanup work.

## Round Closeout Notes

### Round 1

- PostgreSQL is available (`pg_isready` succeeded before execution started).
- Current branch: `codex/kernel-program-audit-report`
- Current unrelated worktree state:
  - untracked `cybros/docs/reports/2026-03-17-cybros-claw-kernel-program-audit.md`
- Discovery noise to ignore:
  - generic fallback behavior
  - i18n fallback configuration
  - archived docs
  - untracked report material
  - the current cleanup design/plan documents when they intentionally mention removal targets

### Round 2

- Archived seven misleading runtime planning docs from active `docs/plans/` into `docs/archive/plans/2026-03/`:
  - `2026-03-08-runtime-governance-design.md`
  - `2026-03-08-runtime-governance.md`
  - `2026-03-09-agent-deployment-connection-design.md`
  - `2026-03-09-automation-runtime-design.md`
  - `2026-03-09-automation-runtime.md`
  - `2026-03-09-execution-target-discovery-design.md`
  - `2026-03-09-runtime-governance-operator-surfaces.md`
- Updated active doc links and index surfaces so live docs no longer point at the old active-plan paths for those files.
- Residual `ExecutionTarget` / `ExecutionLocation` / `AgentDeployment` hits in active `docs/plans/` are now concentrated in:
  - current cleanup/audit materials
  - `2026-03-13-conversation-agent-runtime-simplification-design.md`
  - `2026-03-13-conversation-agent-runtime-simplification.md`
- Later active-doc sweep still needs an explicit keep/archive judgment for:
  - `cybros/docs/plans/2026-03-09-execution-capacity-and-scheduled-automation.md`
  - `cybros/docs/plans/2026-03-10-full-reaudit-baseline.md`

### Round 3

- Removed live `agent_program_key` fallback from:
  - `cybros/app/services/agents/creator.rb`
  - `cybros/app/services/agent_rpc/session_authorizer.rb`
- Cut the bundled claw and cybros fixture contract over to `agent_key` so the real bundled-source path and programmable-agent fixture no longer depend on the legacy noun.
- Added negative coverage proving `agent_program_key`-only manifests and callback identities are rejected.
- Verification:
  - `rg -n "agent_program_key" cybros/app cybros/lib cybros/config` returned no live hits.
  - targeted cybros tests passed for creator/session auth/bootstrap/fixture surfaces.
  - targeted bundled claw tests passed for manifest and RPC contract surfaces.

### Round 4

- Normalized `agent_program_key` fixture payloads to `agent_key` across five explicit verified batches covering:
  - model/runtime fixture helpers
  - lib and DAG tests
  - recovery / replay / hook integration tests
  - automation / run-draft integration and job tests
  - remaining dashboard / bootstrap / routing / capacity / handshake integration tests
- Final grep now leaves `agent_program_key` only in:
  - explicit negative tests that prove legacy payloads are rejected
  - `refute ...key?("agent_program_key")` assertions that prove the new snapshots no longer carry the old key
- Unverified but updated for consistency:
  - `cybros/test/system/system_settings_automations_test.rb`
  - `cybros/test/script/live_acceptance/agent_root_workspace_test.rb`
- Verification commands that passed during this round:
  - `bin/rails test test/scenarios/dag/programmable_agent_step_status_placeholder_test.rb test/services/agent_rpc/lifecycle_caller_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb test/integration/agent_runtime_binding_cutover_test.rb test/integration/agent_rpc_runtime_state_cutover_test.rb test/integration/programmable_agent_execution_test.rb test/integration/conversations_test.rb`
  - `bin/rails test test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/lib/cybros/programmable_agent/tool_execution_test.rb test/lib/cybros/programmable_agent/recognized_deployment_resolver_test.rb test/lib/cybros/programmable_agent_provider_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb test/lib/agent_core/dag/agent_output_finalization_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb`
  - `bin/rails test test/integration/agent_upgrade_conversation_binding_test.rb test/integration/agent_rpc_lost_reply_recovery_test.rb test/integration/agent_rpc_activation_drift_test.rb test/integration/programmable_agent_capabilities_refresh_test.rb test/integration/programmable_agent_hooks_test.rb test/integration/programmable_agent_execution_context_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/bootstrap_hook_contract_test.rb`
  - `bin/rails test test/jobs/automations/execute_conversation_job_test.rb test/integration/system_settings_automations_test.rb test/integration/automation_failure_recovery_test.rb test/integration/automation_execution_conversation_test.rb test/integration/automation_execution_run_draft_flow_test.rb test/integration/automation_manual_approval_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb`
  - `bin/rails test test/integration/dashboard_test.rb test/integration/conversation_bootstrap_dispatch_test.rb test/integration/programmable_agent_tool_routing_test.rb test/integration/agent_execution_capacity_test.rb test/integration/programmable_agent_capabilities_handshake_test.rb test/integration/recognized_deployment_drift_test.rb`

### Round 5

- Tightened `cybros/test/test_helper.rb` so the public fixture contract now uses:
  - `create_conversation!(..., agent:)`
  - `materialize_agent_runtime!(agent:, execution_profile:)`
  - `create_agent_runtime!(agent:, execution_profile:)`
  - `create_runtime_binding_record!(agent:, ...)`
- Added negative coverage proving the removed helper keywords raise `ArgumentError`:
  - `agent_program:`
  - `default_execution_target:`
  - `program:`
  - `execution_target:`
- Verified the first explicit helper-contract batch across:
  - `agent_test`
  - `run_draft_test`
  - `conversation_run_test`
  - `recognized_deployment_test`
  - `lifecycle_caller_test`
  - `agent_rpc_lost_reply_recovery_test`
  - `execution_capacity_enforcement_test`
  - `agent_runtime_binding_cutover_test`
  - `run_draft_finalization_test`
  - `run_draft_approval_resume_test`
- Verification command that passed during this round:
  - `bin/rails test test/models/agent_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb test/models/recognized_deployment_test.rb test/services/agent_rpc/lifecycle_caller_test.rb test/integration/agent_rpc_lost_reply_recovery_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/agent_runtime_binding_cutover_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb`
- Remaining helper-contract residue after this batch is now concentrated in:
  - runtime governance and automation tests
  - agent RPC / attachment / tool execution integration tests
  - lib and DAG runtime-surface tests
  - system and live-acceptance surfaces that were already out of the first verified batch

### Round 6

- Removed execution-target-centric setup from the selected runtime-governance and automation suites by moving capacity facts onto the `Agent` records those tests already own.
- Deleted local `create_execution_target!` scaffolding from:
  - `execution_capacity_resolver_test`
  - `execution_capacity_enforcer_test`
  - `dispatch_test`
  - `dispatch_due_job_test`
  - `execute_conversation_job_test`
  - `automation_test`
  - `automation_failure_recovery_test`
  - `automation_execution_conversation_test`
  - `automation_execution_run_draft_flow_test`
  - `automation_manual_approval_test`
- Simplified the selected integration/unit helpers so they now use:
  - `create_agent_runtime!(agent:, deployment:)`
  - `create_runtime_binding_record!(agent:, ...)`
  - direct `Agent` capacity attributes instead of synthetic execution-profile wrappers
- Kept the shared execution-profile helpers in `test/test_helper.rb` for now because later clusters still depend on them; helper deletion is deferred until those consumers are migrated, rather than leaving the suite half-broken.
- Verification command that passed during this round:
  - `bin/rails test test/services/runtime_governance/execution_capacity_resolver_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/runtime_governance_observability_test.rb test/services/automations/dispatch_test.rb test/jobs/automations/dispatch_due_job_test.rb test/jobs/automations/execute_conversation_job_test.rb test/models/automation_test.rb test/integration/automation_failure_recovery_test.rb test/integration/automation_execution_conversation_test.rb test/integration/automation_execution_run_draft_flow_test.rb test/integration/automation_manual_approval_test.rb`
- Remaining `execution_target` / old runtime-helper residue after this batch is now concentrated in:
  - adjacent runtime governance/system tests (`execution_capacity_leases_test`, `system_settings_runtime_governance_test`)
  - RPC/runtime model tests (`agent_rpc_*`, `recognized_deployment_*`, `run_draft_*`, `conversation_run_*`)
  - programmable-agent tool/runtime-surface tests
  - attachment and system/live-acceptance integration surfaces

### Round 7

- Archived `2026-03-13-conversation-agent-runtime-simplification.md` because it now acts as historical implementation choreography, not an active truth source.
- Updated the doc indexes so active reading order points at current design truth instead of the archived implementation plan:
  - `docs/README.md`
  - `docs/product/README.md`
  - `docs/plans/README.md`
- Active doc hits that still mention old runtime nouns are now limited to:
  - current design docs that explicitly describe the removed model as a removal target
  - current cleanup docs that intentionally inventory legacy nouns during this cleanup
  - the unrelated untracked audit report, which remains outside the tracked cleanup scope

### Round 8

- Cleaned the next explicit helper-contract residue batch across:
  - `test/services/runtime_governance/execution_capacity_leases_test.rb`
  - `test/models/agent_rpc_operation_receipt_test.rb`
  - `test/models/agent_rpc_session_test.rb`
  - `test/models/agent_rpc_invocation_test.rb`
- Removed the last old helper-contract calls in that cluster:
  - `materialize_agent_runtime!(program:, execution_target:)`
  - `create_runtime_binding_record!(agent_program:, ...)`
  - `create_conversation!(..., agent_program:, default_execution_target:)`
- Collapsed `execution_capacity_leases_test` onto direct `Agent` capacity attributes instead of a synthetic execution-target builder.
- Verification command that passed during this round:
  - `bin/rails test test/models/agent_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb test/models/recognized_deployment_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/models/agent_rpc_operation_receipt_test.rb test/models/agent_rpc_session_test.rb test/models/agent_rpc_invocation_test.rb`
- Remaining high-priority helper residue is now concentrated in:
  - agent RPC / recognized deployment integration flows
  - programmable-agent runtime fixture tests
  - attachment and system/live-acceptance surfaces

### Round 9

- Cleaned the next agent RPC / recognized deployment residue batch across:
  - `test/integration/agent_rpc_activation_drift_test.rb`
  - `test/integration/agent_rpc_invocation_replay_test.rb`
  - `test/integration/agent_rpc_runtime_state_cutover_test.rb`
  - `test/integration/recognized_deployment_drift_test.rb`
  - `test/lib/cybros/programmable_agent/recognized_deployment_resolver_test.rb`
- Removed the remaining old helper calls in that cluster:
  - `materialize_agent_runtime!(program:, execution_target:)`
  - `create_runtime_binding_record!(agent_program:, ...)`
  - `create_conversation!(..., agent_program:, default_execution_target:)`
- Simplified the runtime fixtures in those files so the deployment handle is the same live `Agent` record the tests already exercise, instead of synthesizing a separate target-backed layer.
- Verification commands for this round:
  - red check: `bin/rails test test/integration/agent_rpc_activation_drift_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/agent_rpc_runtime_state_cutover_test.rb test/integration/recognized_deployment_drift_test.rb test/lib/cybros/programmable_agent/recognized_deployment_resolver_test.rb` -> 16 errors, all from the removed helper keywords
  - green check: `bin/rails test test/integration/agent_rpc_activation_drift_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/agent_rpc_runtime_state_cutover_test.rb test/integration/recognized_deployment_drift_test.rb test/lib/cybros/programmable_agent/recognized_deployment_resolver_test.rb`
- Remaining high-priority helper residue is now concentrated in:
  - programmable-agent tool/runtime-surface tests
  - attachment transfer and conversation attachment integration tests
  - system and live-acceptance surfaces
  - a smaller set of dashboard/bootstrap/conversation bootstrap runtime helpers

### Round 10

- Cleaned the attachment and tool-runtime residue batch across:
  - `test/integration/external_agent_attachment_transfer_test.rb`
  - `test/integration/conversation_attachment_upload_gate_test.rb`
  - `test/integration/attachment_prompt_injection_test.rb`
  - `test/lib/cybros/programmable_agent/tool_execution_test.rb`
  - `test/integration/programmable_agent_tool_routing_test.rb`
- Removed the remaining old helper calls in that cluster:
  - `create_runtime_binding_record!(agent_program:, ...)`
  - `materialize_agent_runtime!(program:, execution_target:)`
  - `create_agent_runtime!(program:, execution_target:)`
  - `create_conversation!(..., agent_program:, default_execution_target:)`
- Kept the execution-profile builders only where those tests still need workspace/capacity fixture facts; the cleanup here was strictly about cutting out the removed program/target compatibility layer.
- Verification commands for this round:
  - red check: `bin/rails test test/integration/external_agent_attachment_transfer_test.rb test/integration/conversation_attachment_upload_gate_test.rb test/integration/attachment_prompt_injection_test.rb test/lib/cybros/programmable_agent/tool_execution_test.rb test/integration/programmable_agent_tool_routing_test.rb` -> 19 errors, all from the removed helper keywords
  - green check: `bin/rails test test/integration/external_agent_attachment_transfer_test.rb test/integration/conversation_attachment_upload_gate_test.rb test/integration/attachment_prompt_injection_test.rb test/lib/cybros/programmable_agent/tool_execution_test.rb test/integration/programmable_agent_tool_routing_test.rb`
- Remaining high-priority helper residue is now concentrated in:
  - dashboard / bootstrap / programmable-agent execution integration helpers
  - DAG and runtime-surface lib tests
  - system and live-acceptance surfaces

### Round 11

- Cleaned the dashboard / bootstrap / programmable execution integration residue batch across:
  - `test/integration/dashboard_test.rb`
  - `test/integration/conversation_bootstrap_dispatch_test.rb`
  - `test/integration/bootstrap_hook_contract_test.rb`
  - `test/integration/programmable_agent_execution_test.rb`
  - `test/integration/programmable_agent_capabilities_refresh_test.rb`
- Removed the remaining old helper calls in that cluster:
  - `create_runtime_binding_record!(agent_program:, ...)`
  - `materialize_agent_runtime!(program:)`
  - `materialize_agent_runtime!(program:, execution_target:)`
  - `create_agent_runtime!(program:, execution_target:)`
- Verification commands for this round:
  - red check: `bin/rails test test/integration/dashboard_test.rb test/integration/conversation_bootstrap_dispatch_test.rb test/integration/bootstrap_hook_contract_test.rb test/integration/programmable_agent_execution_test.rb test/integration/programmable_agent_capabilities_refresh_test.rb` -> 10 errors, all from the removed helper keywords
  - green check: `bin/rails test test/integration/dashboard_test.rb test/integration/conversation_bootstrap_dispatch_test.rb test/integration/bootstrap_hook_contract_test.rb test/integration/programmable_agent_execution_test.rb test/integration/programmable_agent_capabilities_refresh_test.rb`
- Remaining high-priority helper residue is now concentrated in:
  - runtime-governance and operator-surface integration tests
  - DAG and runtime-surface lib tests
  - system and live-acceptance surfaces

### Round 12

- Cleaned the runtime-governance / operator-surface integration residue batch across:
  - `test/integration/system_settings_automations_test.rb`
  - `test/integration/system_settings_runtime_governance_test.rb`
  - `test/integration/automation_scheduler_flow_test.rb`
  - `test/integration/agent_execution_capacity_test.rb`
- Removed the remaining old helper calls in that cluster:
  - `create_runtime_binding_record!(agent_program:, ...)`
  - `materialize_agent_runtime!(program:, execution_target:)`
  - `create_agent_runtime!(program:, execution_target:)`
- Kept local execution-profile builders where the tests still need capacity fixtures for observability assertions; this round only cut out the obsolete helper contract.
- Verification commands for this round:
  - red check: `bin/rails test test/integration/system_settings_automations_test.rb test/integration/system_settings_runtime_governance_test.rb test/integration/automation_scheduler_flow_test.rb test/integration/agent_execution_capacity_test.rb` -> 5 errors, all from the removed helper keywords
  - green check: `bin/rails test test/integration/system_settings_automations_test.rb test/integration/system_settings_runtime_governance_test.rb test/integration/automation_scheduler_flow_test.rb test/integration/agent_execution_capacity_test.rb`
- Remaining high-priority helper residue is now concentrated in:
  - DAG and runtime-surface lib tests
  - system and live-acceptance surfaces
  - a smaller number of scenario/model tests still carrying local execution-target fixture builders

### Round 13

- Cleaned the first lib runtime-surface residue batch across:
  - `test/lib/cybros/programmable_agent_provider_test.rb`
  - `test/lib/cybros/programmable_agent/hook_action_executor_test.rb`
  - `test/lib/agent_core/dag/agent_output_finalization_test.rb`
  - `test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`
  - `test/lib/dag/runner_test.rb`
- Removed the remaining old helper calls in that cluster:
  - `create_runtime_binding_record!(agent_program:, ...)`
  - `create_agent_runtime!(program:, execution_target:)`
- The initial red run also restored the hidden signal that several of those tests were expecting domain validation failures, not helper argument errors; after the helper cleanup, those original assertions passed again unchanged.
- Verification commands for this round:
  - red check: `bin/rails test test/lib/cybros/programmable_agent_provider_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/lib/agent_core/dag/agent_output_finalization_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb test/lib/dag/runner_test.rb` -> 28 errors and 2 expectation failures, all caused by the removed helper keywords surfacing ahead of the real domain assertions
  - green check: `bin/rails test test/lib/cybros/programmable_agent_provider_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/lib/agent_core/dag/agent_output_finalization_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb test/lib/dag/runner_test.rb`
- Remaining high-priority helper residue is now concentrated in:
  - `task_executor_runtime_surface_test` and `agent_runtime_resolver_llm_provider_test`
  - scenario tests with local runtime builders
  - system and live-acceptance surfaces
  - a few model/integration helpers that still keep local execution-target builders for capacity setup

## Reusable Strategy Notes

- Always separate “search noise” from real cleanup targets before batching work.
- Treat active docs, live code, and test helper APIs as separate truth-source layers.
- Do not widen a batch just because a grep returns many hits; record the overflow in the ledger and keep the batch explicit.
- Negative tests are required for compatibility-removal work; fixture renames alone are not enough proof.
