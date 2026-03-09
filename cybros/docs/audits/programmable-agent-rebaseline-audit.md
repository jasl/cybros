# Programmable Agent Rebaseline Audit

This document tracks the findings from the current `codex/programmable-agent-rebaseline` audit and their repair status.

Environment note:

- Audit verification was rerun from a clean `test` database after an initial false failure caused by stale `rails runner` data left in `cybros_test`.
- Fresh evidence below comes from rerun Rails batches, Playwright E2E, current source inspection, and explicit file-existence checks.
- During this repair pass, progress and closure state are recorded here. Product docs and plan docs remain the semantic baseline until the final full re-review reconciles any true documentation drift.

## Repair Status

- Closed on 2026-03-09: `PA-001`, `PA-002`, `PA-003`, `PA-004`, `PA-005`, `PA-007`, `PA-008`, `PA-009`, `PA-010`, `PA-011`, `PA-012`, `PA-013`
- Still open: `PA-006`
- Explicitly excluded from implementation in this repair session: `PA-006`

## PA-001

- Status: Closed on 2026-03-09.
- Repair summary: `execution_target.propose` now keeps the approval boundary in Cybros-owned kernel logic for `confirm`, and planning preserves the kernel-owned approval state when the agent response omits it.
- Verification: `bin/rails test test/integration/run_draft_target_switch_policy_test.rb test/integration/run_draft_approval_resume_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P1
- Conclusion: `execution_target.propose` does not enforce the documented `confirm` path. For `confirm`, Cybros stages the new target immediately and only parks if the agent voluntarily returns an `approval_state`, so a target switch that should require human confirmation can finalize without approval.
- Violates:
  - `docs/plans/2026-03-09-execution-target-discovery-design.md` says `execution_target.propose` is draft-only and Cybros owns the `allow` / `confirm` / `deny` flow, including parking and local resume.
  - `docs/product/run_lifecycle.md` says Cybros evaluates target proposals and parks when policy or approval requires a human decision.
- Evidence:
  - [`app/services/agent_rpc/kernel_services/execution_targets.rb:46`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/execution_targets.rb#L46) computes `switch_decision`.
  - [`app/services/agent_rpc/kernel_services/execution_targets.rb:65`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/execution_targets.rb#L65) applies the proposal for both `"allow"` and `"confirm"`.
  - [`app/services/run_drafts/conversation_turn_planning_service.rb:39`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/conversation_turn_planning_service.rb#L39) only parks if the RPC response already contains an approval state.
  - [`lib/cybros/programmable_agent_fixture.rb:179`](/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/programmable_agent_fixture.rb#L179) shows the current happy path depends on the fixture echoing `approval_state` back after seeing `confirm`.
- Impact:
  - A non-compliant or buggy agent can bypass target-switch approval semantics in `default` / `conservative` mode.
  - The kernel no longer owns the approval boundary the plans describe.
- Possible options:
  - Enforce parking inside `execution_target.propose` whenever `switch_decision.decision == "confirm"`.
  - Reject `confirm` proposals unless the kernel transitions the draft into an explicit approval-required state itself.
- Recommended solution:
  - Move the `confirm` transition into Cybros-owned kernel logic and add a regression test where the agent proposes a different visible target but does not return `approval_state`.

## PA-002

- Status: Closed on 2026-03-09.
- Repair summary: callback dispatch now evaluates public-state mutation policy through the compiled permission preset summary, stages kernel-owned approval for `confirm`, and keeps replayed callback mutations idempotent under the parked draft state.
- Verification:
  - `bin/rails test test/services/runtime_governance/public_state_mutation_policy_test.rb test/integration/run_draft_finalization_test.rb`
  - `bin/rails test test/services/runtime_governance/public_state_mutation_policy_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P1
- Conclusion: conversation settings/config/KV mutation callbacks are staged without any permission-policy decision. The compiled preset summary mentions public-state mutation behavior, but the callback path never consults it.
- Violates:
  - `docs/plans/2026-03-09-permission-presets-design.md` requires one unified compiled bundle for tools, public-state mutations, target switches, and execution-boundary behavior.
  - `docs/product/kernel_service_surface.md` keeps these kernel surfaces under Cybros-owned policy and approval semantics.
- Evidence:
  - [`app/services/agent_rpc/callback_dispatcher.rb:33`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/callback_dispatcher.rb#L33), [`:38`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/callback_dispatcher.rb#L38), and [`:42`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/callback_dispatcher.rb#L42) call update/set/delete handlers directly.
  - [`app/services/agent_rpc/kernel_services/conversation_settings.rb:20`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/conversation_settings.rb#L20), [`conversation_config.rb:20`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/conversation_config.rb#L20), and [`conversation_kv.rb:29`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/conversation_kv.rb#L29) immediately stage mutations.
  - [`lib/cybros/permissions/bundle_compiler.rb:115`](/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/permissions/bundle_compiler.rb#L115) only emits summary metadata for `public_state_mutations`; nothing in the callback path consumes it.
- Impact:
  - `conservative` and `default` modes do not actually govern public-state mutations.
  - Approval semantics for conversation-side state changes are effectively bypassed.
- Possible options:
  - Add a dedicated public-state mutation policy evaluator in the callback path.
  - Compile public-state mutation defaults into an enforceable runtime object, not just summary metadata.
- Recommended solution:
  - Introduce explicit `allow` / `confirm` / `deny` evaluation for `conversation.settings.update`, `conversation.config.update`, `conversation.kv.set`, and `conversation.kv.delete`, then add coverage for a mutation that must park or reject under `conservative`.

## PA-003

- Status: Closed on 2026-03-09.
- Repair summary: finalization now keeps the parked draft's snapshotted permission mode authoritative instead of staling the draft when the live conversation preset changes after parking.
- Verification: `bin/rails test test/integration/run_draft_approval_resume_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P1
- Conclusion: changing `Conversation.permission_mode` after a draft parks can stale the parked draft, even though the design says preset changes only affect future drafts and runs.
- Violates:
  - `docs/plans/2026-03-09-permission-presets-design.md` says a parked draft that already snapshotted its effective mode must not be retroactively changed.
  - `docs/product/run_lifecycle.md` says finalization pins one effective permission preset for the run.
- Evidence:
  - [`app/services/run_drafts/finalize_service.rb:111`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/finalize_service.rb#L111) re-resolves current bindings during finalization.
  - [`app/services/run_drafts/finalize_service.rb:119`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/finalize_service.rb#L119) requires the re-resolved permission mode to equal the draft snapshot.
  - [`app/services/runtime_governance/draft_governor_resolver.rb:83`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/runtime_governance/draft_governor_resolver.rb#L83) derives permission mode from the current entrypoint state.
  - No rerun test covers changing `conversation.permission_mode` between park and resume; `rg -n "permission_mode" test/integration/run_draft_approval_resume_test.rb test/integration/run_draft_finalization_test.rb` only finds setup/default assertions, not this case.
- Impact:
  - Operators or users can unintentionally break approval resume for already parked work.
  - The run snapshot boundary becomes retroactive, which contradicts the documented lifecycle.
- Possible options:
  - Exclude permission-mode drift from stale-binding checks for already snapshotted parked drafts.
  - Separate re-resolvable live governor bindings from immutable draft snapshot fields.
- Recommended solution:
  - Keep the draft’s snapshotted permission mode authoritative after planning completes, and add an approval-resume regression test that changes the conversation preset before approval.

## PA-004

- Status: Closed on 2026-03-09.
- Repair summary: invocation replay is now pinned to `agent_deployment_id` in both persistence and replay validation, with a migration updating the uniqueness boundary.
- Verification: `bin/rails test test/models/agent_rpc_invocation_test.rb test/integration/agent_rpc_invocation_replay_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P1
- Conclusion: invocation replay is not pinned to the `agent_deployment_id`; it is keyed only by fingerprint + activation epoch + scope + method. That leaves a contract-integrity gap whenever a second deployment row preserves the copied binding fields.
- Violates:
  - `docs/product/agent_contract.md` says `RunDraft` pins `agent_deployment_id` in addition to fingerprint and activation epoch.
  - `docs/product/run_lifecycle.md` says replay is valid only against the same pinned binding.
- Evidence:
  - [`app/models/agent_rpc_invocation.rb:14`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/agent_rpc_invocation.rb#L14) scopes `invocation_id` uniqueness to binding fingerprint, activation epoch, scope, and method, not `agent_deployment_id`.
  - [`app/services/agent_rpc/invocation_store.rb:126`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/invocation_store.rb#L126) checks replay binding equality only through fingerprint and activation time.
  - [`test/integration/agent_rpc_invocation_replay_test.rb:36`](/Users/jasl/Workspaces/Cybros/cybros/cybros/test/integration/agent_rpc_invocation_replay_test.rb#L36) only tests a changed fingerprint case, not a different deployment row with copied binding fields.
- Impact:
  - Replay identity is weaker than the documented binding contract.
  - Audit and idempotency semantics are weaker than the plan requires, even though this audit did not produce a full end-to-end row-substitution exploit.
- Possible options:
  - Include `agent_deployment_id` in the invocation uniqueness boundary and replay equality check.
  - Introduce an explicit immutable binding identifier persisted on the invocation and session records.
- Recommended solution:
  - Bind replay to `agent_deployment_id` as well as fingerprint/activation epoch, and add a regression test that uses a second deployment row with identical binding fields.

## PA-005

- Status: Closed on 2026-03-09.
- Repair summary: inspection now requires `initialize` to return an explicit negotiated `protocol_version` instead of falling back to the registration seed.
- Verification: `bin/rails test test/integration/agent_deployments_inspection_test.rb test/integration/agent_deployments_activation_gate_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P1
- Conclusion: activation can succeed even when `initialize` omitted `protocol_version`. Registration seeds `agent_rpc.v1`, inspection falls back to the stored field, and activation only checks that stored field.
- Violates:
  - `docs/product/agent_rpc.md` says initialization must negotiate at least `protocol_version`.
  - `docs/plans/2026-03-09-agent-deployment-connection.md` requires activation on exact supported protocol version after inspection.
- Evidence:
  - [`app/services/agent_deployments/registration_service.rb:21`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_deployments/registration_service.rb#L21) seeds `protocol_version` at registration.
  - [`app/services/agent_deployments/inspection_service.rb:18`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_deployments/inspection_service.rb#L18) uses `identity.fetch("protocol_version", deployment.protocol_version)`.
  - [`app/services/agent_deployments/activation_service.rb:9`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_deployments/activation_service.rb#L9) checks only `deployment.protocol_version == SUPPORTED_PROTOCOL_VERSION`.
  - [`test/integration/agent_deployments_activation_gate_test.rb:24`](/Users/jasl/Workspaces/Cybros/cybros/cybros/test/integration/agent_deployments_activation_gate_test.rb#L24) covers explicit `agent_rpc.v2`, not omission.
- Impact:
  - Activation can pass without an actual negotiated protocol version from the deployment.
  - Compatibility guarantees are weaker than the inspection/activation contract claims.
- Possible options:
  - Require `identity["protocol_version"]` to be present and exact during inspection.
  - Persist a separate `negotiated_protocol_version` only when initialize returns it explicitly.
- Recommended solution:
  - Fail inspection or activation when `initialize` omits `protocol_version`, and add an activation test for omission.

## PA-006

- Status: Open discussion item; explicitly excluded from implementation in the 2026-03-09 repair session.

- Severity: P2
- Conclusion: runtime-governance Task 6 is currently a plan/implementation mismatch, not a closed acceptance slice. The branch ships only part of the operator surface while the plan still claims a broader settings and observability scope.
- Violates:
  - `docs/plans/2026-03-08-runtime-governance.md` Task 6.
- Evidence:
  - [`docs/plans/2026-03-08-runtime-governance.md:123`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-08-runtime-governance.md#L123) defines the missing task scope.
  - [`config/routes.rb:15`](/Users/jasl/Workspaces/Cybros/cybros/cybros/config/routes.rb#L15) exposes `llm_providers`, `agent_programs`, `agent_deployments`, `execution_targets`, and `automations`, but no runtime-settings, execution-locations, or workspaces settings surfaces.
  - `bin/rails test test/integration/system_settings_runtime_governance_test.rb test/integration/runtime_governance_observability_test.rb` currently fails with `Rails::TestUnit::InvalidTestError` because the files do not exist.
  - `rg -n "system_settings_runtime_governance|runtime_governance_observability|ExecutionLocationController|WorkspacesController|RuntimeSettingsController" cybros -S` only hits the plan doc, not implementation.
- Impact:
  - The operator cannot rely on Task 6 as an acceptance-complete slice.
  - Remaining closure criteria are ambiguous until the plan is split, descoped, or finished.
- Possible options:
  - Split Task 6 into the shipped slice versus remaining settings/observability work.
  - Or explicitly descoped/rewrite Task 6 and its acceptance language before treating the rebaseline as complete.
- Recommended solution:
  - Treat this as an acceptance blocker until the plan or implementation is brought back into alignment.

## PA-007

- Status: Closed on 2026-03-09.
- Repair summary: activation now requires `turn.handle_error`, the fixture advertises and implements it, and the programmable runtime invokes it when `turn.compose` fails.
- Verification: `bin/rails test test/integration/programmable_agent_execution_test.rb test/integration/agent_deployments_activation_gate_test.rb test/lib/cybros/programmable_agent_fixture_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P1
- Conclusion: `turn.handle_error` is not wired into the runtime path, and the activation contract also omits it. The documented failure hook is therefore neither required nor used.
- Violates:
  - `docs/product/agent_rpc.md` defines `turn.handle_error` as a core Cybros-to-agent turn hook.
  - `docs/product/run_lifecycle.md` includes `turn.handle_error` in the canonical failure path.
- Evidence:
  - [`app/services/agent_deployments.rb:3`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_deployments.rb#L3) lists required methods and omits `turn.handle_error`.
  - [`lib/cybros/programmable_agent_provider.rb:47`](/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/cybros/programmable_agent_provider.rb#L47) only invokes `turn.compose`.
  - [`app/models/conversation_run.rb:55`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/conversation_run.rb#L55) defines `handle_error_invocation_id`, but `rg -n "turn\\.handle_error|handle_error_invocation_id" app lib test -S` finds no runtime call site beyond that helper.
  - [`test/integration/agent_deployments_activation_gate_test.rb:4`](/Users/jasl/Workspaces/Cybros/cybros/cybros/test/integration/agent_deployments_activation_gate_test.rb#L4) only validates the reduced required-method set.
- Impact:
  - Failure-path compatibility is not guaranteed for activated deployments.
  - Even adding the method to activation would not restore the documented behavior until the runtime actually invokes it.
- Possible options:
  - Wire `turn.handle_error` into the conversation-run failure path and require it in activation.
  - Or revise the product docs to explicitly defer the hook from both runtime behavior and activation.
- Recommended solution:
  - Align the implementation upward: add the runtime invocation path first, then require `turn.handle_error` in activation/fixtures with regression coverage.

## PA-008

- Status: Closed on 2026-03-09.
- Repair summary: successful health responses now normalize to the internal `"healthy"` state, so activation does not depend on an undocumented success label.
- Verification: `bin/rails test test/integration/agent_deployments_inspection_test.rb test/integration/agent_deployments_activation_gate_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P2
- Conclusion: health success is effectively keyed to the literal string `"healthy"`, even though inspection preserves arbitrary successful health statuses.
- Violates:
  - The product docs require a healthy inspection result, not specifically the string `"healthy"`.
- Evidence:
  - [`app/services/agent_deployments/inspection_service.rb:64`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_deployments/inspection_service.rb#L64) preserves `result["status"]` when `healthy == true`, including `"ok"`.
  - [`app/services/agent_deployments/activation_service.rb:10`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_deployments/activation_service.rb#L10) only accepts `deployment.health_status == "healthy"`.
  - [`test/integration/agent_deployments_activation_gate_test.rb:45`](/Users/jasl/Workspaces/Cybros/cybros/cybros/test/integration/agent_deployments_activation_gate_test.rb#L45) only covers `healthy: false`, not alternate successful status strings.
- Impact:
  - A deployment that reports `{ healthy: true, status: "ok" }` can inspect successfully but still fail activation/selectability.
  - The runtime contract depends on an undocumented string literal.
- Possible options:
  - Normalize all successful health responses to `"healthy"`.
  - Or gate activation on a boolean success flag / normalized healthy class instead of a literal status string.
- Recommended solution:
  - Normalize success to a stable internal healthy state and add coverage for alternate success labels.

## PA-009

- Status: Closed on 2026-03-09.
- Repair summary: automation drafts now resolve one canonical bound conversation for conversation-scoped kernel services and approval/rejection/expiry node synchronization.
- Verification: `bin/rails test test/integration/automation_conversation_binding_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P1
- Conclusion: conversation-bound automations advertise `conversation.*` callbacks during planning, but the resulting `RunDraft` cannot carry `conversation_id`. The callback handlers and approval/expiry node sync paths dereference `draft.conversation` and therefore break or silently skip the bound conversation path.
- Violates:
  - `docs/product/automation.md` says conversation-bound automations may use conversation-scoped settings/config while remaining first-class automation runs.
  - `docs/product/kernel_service_surface.md` keeps conversation-side callbacks under Cybros-owned kernel services.
- Evidence:
  - [`app/services/run_drafts/automation_planning_service.rb:191`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/automation_planning_service.rb#L191) enables the full conversation callback set whenever `bound_conversation.present?`.
  - [`app/services/run_drafts/automation_planning_service.rb:56`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/automation_planning_service.rb#L56) creates the automation draft without `conversation: bound_conversation`.
  - [`app/models/run_draft.rb:41`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/run_draft.rb#L41) enforces exactly one entrypoint, so an automation draft cannot also carry `conversation_id`.
  - [`app/services/agent_rpc/kernel_services/conversation_settings.rb:35`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/conversation_settings.rb#L35), [`conversation_config.rb:35`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/conversation_config.rb#L35), and [`conversation_kv.rb:60`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/conversation_kv.rb#L60) resolve callbacks through `draft.conversation`.
  - [`app/services/run_drafts/approval_resume_service.rb:98`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/approval_resume_service.rb#L98) and [`approval_expiry_service.rb:42`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/approval_expiry_service.rb#L42) also require `draft.conversation.present?` before synchronizing the bound DAG node.
- Impact:
  - Conversation-bound automations can plan against a conversation but fail on conversation callback mutation paths.
  - Approval, rejection, and expiry can miss the bound DAG node even when `trigger_snapshot` already carries `conversation_id` and `dag_node_id`.
- Possible options:
  - Allow automation drafts to carry a bound conversation separately from the automation entrypoint.
  - Or resolve the bound conversation consistently from `trigger_snapshot` / automation metadata everywhere callbacks and approval sync need it.
- Recommended solution:
  - Introduce one canonical “bound conversation” resolver for automation drafts and add conversation-bound approval/callback integration coverage.

## PA-010

- Status: Closed on 2026-03-09.
- Repair summary: conversation planning payloads and `conversation.config.get` now read config through the draft-selected program namespace instead of the live conversation selection.
- Verification: `bin/rails test test/integration/run_draft_finalization_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P2
- Conclusion: interactive conversation planning and `conversation.config.get` are not fully pinned to the draft-selected program. They read from the conversation’s current selected program, while finalization writes staged config under `draft.agent_program`. The automation planning path already uses the draft-selected program correctly.
- Violates:
  - `docs/plans/2026-03-09-agent-deployment-connection.md` requires config namespacing across agent switches.
  - `docs/product/run_lifecycle.md` says the run executes under pinned runtime inputs.
- Evidence:
  - [`app/services/run_drafts/conversation_turn_planning_service.rb:127`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/conversation_turn_planning_service.rb#L127) sends `conversation.selected_agent_config`, not `selected_agent_config_for(draft.agent_program)`.
  - [`app/services/agent_rpc/kernel_services/conversation_config.rb:16`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/agent_rpc/kernel_services/conversation_config.rb#L16) returns `conversation.selected_agent_config`.
  - [`app/services/conversations/runtime_settings_updater.rb:14`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/conversations/runtime_settings_updater.rb#L14) lets the live conversation switch `agent_program_id` independently while a draft is parked.
  - [`app/services/run_drafts/finalize_service.rb:150`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/finalize_service.rb#L150) writes staged config into `draft.agent_program`’s namespace, and [`app/services/run_drafts/finalize_service.rb:210`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/finalize_service.rb#L210) snapshots `selected_agent_config_for(draft.agent_program)`.
  - [`app/services/run_drafts/automation_planning_service.rb:209`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/run_drafts/automation_planning_service.rb#L209) shows the narrower, correct behavior already exists on the automation path.
- Impact:
  - A parked or in-flight interactive draft can read config from one program and finalize under another program’s namespace.
  - Snapshot/config coherence across agent switches is not guaranteed on the conversation path.
- Possible options:
  - Make all interactive config reads draft-bound once planning opens.
  - Freeze the conversation’s selected program for the duration of an open draft.
- Recommended solution:
  - Route interactive planning-time config reads through `draft.agent_program` consistently and add a regression test that switches agents while a draft is parked.

## PA-011

- Status: Closed on 2026-03-09.
- Repair summary: execution capacity admission now happens at the DAG claim boundary, parked waits derive `waiting_for_capacity` from durable `RuntimeWait` facts, and lease release wakes the oldest parked waiter by clearing retry gating and kicking the graph.
- Verification:
  - `bin/rails test test/lib/dag/scheduler_test.rb test/lib/dag/runner_test.rb test/jobs/dag/tick_graph_job_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/programmable_agent_execution_test.rb`
  - `bin/rails test test/services/runtime_governance/runtime_waits_test.rb test/jobs/dag/tick_graph_job_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/automation_scheduler_flow_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P1
- Conclusion: execution capacity admission was not wired into the real programmable-runtime path. The prior tests exercised the enforcer directly, but production orchestration did not admit or release runs through it.
- Violates:
  - `docs/plans/2026-03-08-runtime-governance.md` says execution admission uses durable capacity leases and parked waits.
  - `docs/product/run_lifecycle.md` says Cybros executes the run under the pinned governor snapshot.
- Evidence:
  - `ConversationRun` runtime snapshots now use `runtime_governors["execution_capacity"]`, and the scheduler admits capacity before claiming a programmable node for execution.
  - [`lib/dag/scheduler.rb:115`](/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/dag/scheduler.rb#L115) admits, parks, or denies execution capacity during the real claim path.
  - [`app/models/conversation_run_tracker.rb:35`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/models/conversation_run_tracker.rb#L35) releases capacity from terminal execution transitions.
  - [`app/services/runtime_governance/runtime_waits.rb:46`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/runtime_governance/runtime_waits.rb#L46) resumes the oldest parked waiter by clearing node retry gating and kicking the graph.
  - [`test/integration/execution_capacity_enforcement_test.rb:4`](/Users/jasl/Workspaces/Cybros/cybros/cybros/test/integration/execution_capacity_enforcement_test.rb#L4) covers real claim-time park, deny, derived runtime state, and release wakeup.
- Impact:
  - Real programmable runs no longer bypass execution capacity governance.
  - Acceptance evidence now exercises the shipped runtime path instead of a manual-service shortcut.
- Possible options:
  - Admit/release in run finalization plus lifecycle transitions.
  - Or admit/release in the worker/node execution path before work is actually claimed.
- Recommended solution:
  - Landed.

## PA-012

- Status: Closed on 2026-03-09.
- Repair summary: scheduled automation now runs through production jobs: a recurring dispatch job finds due automations, dispatch enqueues durable execute work, and scheduled-flow/operator tests assert the real job-wired path instead of manual orchestrator starts.
- Verification:
  - `bin/rails test test/services/automations/dispatch_test.rb test/integration/automation_scheduler_flow_test.rb test/jobs/automations/dispatch_due_job_test.rb test/jobs/automations/execute_run_job_test.rb`
  - `bin/rails test test/integration/automation_run_draft_flow_test.rb test/integration/automation_scheduler_flow_test.rb test/integration/automation_failure_recovery_test.rb test/integration/system_settings_automations_test.rb test/system/system_settings_automations_test.rb`
  - `bin/rails test test/integration/automation_manual_approval_test.rb test/integration/automation_conversation_binding_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P1
- Conclusion: scheduled automation dispatch is not wired to execution. The scheduler only persists queued `AutomationRun` rows; no production path enqueues or starts `Automations::RunOrchestrator` from that scheduled dispatch.
- Violates:
  - `docs/product/automation.md` says automation runtime follows the canonical lifecycle from trigger to run execution.
  - `docs/plans/2026-03-09-automation-runtime.md` Task 5 requires one end-to-end scheduled dispatch flow.
- Evidence:
  - [`app/jobs/automations/dispatch_due_job.rb:1`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/jobs/automations/dispatch_due_job.rb#L1) provides production recurring dispatch execution.
  - [`app/services/automations/dispatch.rb:32`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/automations/dispatch.rb#L32) creates the durable queued `AutomationRun` inside a transaction and enqueues `Automations::ExecuteRunJob`.
  - [`app/jobs/automations/execute_run_job.rb:1`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/jobs/automations/execute_run_job.rb#L1) bridges queued automation runs into the existing orchestration path.
  - [`config/recurring.yml:1`](/Users/jasl/Workspaces/Cybros/cybros/cybros/config/recurring.yml#L1) wires scheduled dispatch into the production recurring job config.
  - Scheduled-flow and operator-surface tests now drive `Automations::ExecuteRunJob` instead of manual `RunOrchestrator.start!`.
- Impact:
  - Due scheduled automations no longer accumulate as inert queued rows.
  - Operator-visible states are now produced by the shipped scheduled path.
- Possible options:
  - Enqueue an automation-run execution job from `Dispatch` / `Scheduler`.
  - Or make the scheduler itself execute orchestration inline, with explicit retry semantics.
- Recommended solution:
  - Landed.

## PA-013

- Status: Closed on 2026-03-09.
- Repair summary: released provider-budget reservations remain inside the rolling request/token accounting window, so failed calls still count against RPM and TPM limits.
- Verification: `bin/rails test test/services/runtime_governance/provider_budget_reservations_test.rb`
- Historical finding retained below for traceability; it no longer describes current behavior.

- Severity: P2
- Conclusion: failed provider calls fall out of the rolling request/token budget window. The error path marks reservations `released`, while rolling window accounting only counts `active` and `settled`.
- Violates:
  - `docs/product/runtime_governance.md` defines `requests_per_minute`, `tokens_per_minute`, and backoff as durable provider-governance inputs.
  - `docs/plans/2026-03-08-runtime-governance.md` says provider admission uses durable budget reservations and waits.
- Evidence:
  - [`lib/agent_core/resources/provider/simple_inference_provider.rb:230`](/Users/jasl/Workspaces/Cybros/cybros/cybros/lib/agent_core/resources/provider/simple_inference_provider.rb#L230) releases the reservation on any provider exception.
  - [`app/services/runtime_governance/provider_budget_reservations.rb:75`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/runtime_governance/provider_budget_reservations.rb#L75) marks the reservation `released`.
  - [`app/services/runtime_governance/provider_budget_reservations.rb:3`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/runtime_governance/provider_budget_reservations.rb#L3) defines the rolling-window statuses as only `active` and `settled`.
  - [`app/services/runtime_governance/provider_budget_reservations.rb:103`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/services/runtime_governance/provider_budget_reservations.rb#L103) calculates requests-per-minute and tokens-per-minute from that reduced status set.
  - [`test/services/runtime_governance/provider_budget_reservations_test.rb:97`](/Users/jasl/Workspaces/Cybros/cybros/cybros/test/services/runtime_governance/provider_budget_reservations_test.rb#L97) covers settled-window exhaustion, but there is no equivalent failure/release regression.
- Impact:
  - Rapid provider failures can retry-storm past the rolling RPM/TPM governor.
  - Backoff policy exists in the snapshot, but failed-call accounting is too weak to support it.
- Possible options:
  - Count released-failure reservations in the rolling window.
  - Or persist a separate failure status that remains window-active until expiry.
- Recommended solution:
  - Keep failed attempts in rolling-window accounting and add a failing-provider limiter regression.
