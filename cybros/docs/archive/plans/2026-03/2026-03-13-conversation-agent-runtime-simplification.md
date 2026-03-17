# Conversation Agent Runtime Simplification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Simplify the V1 Cybros runtime around `Conversation -> Agent -> RecognizedDeployment -> ConversationRun`, move execution-capacity policy onto `Agent`, add conversation-owned logical workspaces plus attachment transfer, and remove execution-target/deployment complexity from the product path while preserving runtime observability.

**Architecture:** Replace the current programmable-agent runtime model outright so conversation configuration points at a user-visible `Agent`, execution-capacity policy resolves from that agent, each turn resolves a normalized `RecognizedDeployment`, and historical/debug/statistics data key off recognized runtime identities rather than mutable deployment objects. Attachment transfer should use an explicit `attachments.import` protocol with signed URLs rather than raw bytes over RPC. Because this cutover is intentionally breaking and the database can be reset, implementation should delete obsolete runtime models and surfaces instead of carrying adapter-heavy compatibility layers.

**Tech Stack:** Ruby on Rails, ActiveRecord, PostgreSQL JSONB and foreign keys, Active Storage, DAG graph/lane/node runtime, programmable-agent hook and RPC lifecycle services, statistics fact projection, bundled/default local agent host

**Execution Status (2026-03-13):**
- Batch 1 is already implemented and re-reviewed: Tasks 1-3 plus follow-up fixes for execution-target source-of-truth, recognized-deployment key scoping, and snapshot accessor drift.
- Remaining execution resumes at Task 4.
- User-mandated delivery gates: Dashboard becomes the primary `Agent` launcher, generic `New Conversation` entry points are removed, legacy cleanup stays the final deliberate cleanup task, and final acceptance requires both `bin/ci` and `bin/ci_e2e`.
- Audit update: the first stale-surface scan showed Task 15 is not a small final cleanup. The remaining work is concentrated in live runtime internals, not just routes/views/docs. The plan below therefore expands legacy cleanup into multiple runtime rewrite tasks before final deletion and delivery verification.

**Legacy Cleanup Scan (2026-03-13):**
- Core model adapter layer still carries legacy runtime ids and lookup helpers:
  - `cybros/app/models/conversation.rb`
  - `cybros/app/models/automation.rb`
  - `cybros/app/models/run_draft.rb`
  - `cybros/app/models/conversation_run.rb`
  - `cybros/app/models/agent.rb`
  - `cybros/app/models/agent_rpc_session.rb`
  - `cybros/app/models/agent_rpc_invocation.rb`
  - `cybros/app/models/recognized_deployment.rb`
- Runtime planning/finalization and RPC authorization still use `AgentDeployment` or `execution_target.*`:
  - `cybros/app/services/run_drafts/conversation_turn_planning_service.rb`
  - `cybros/app/services/run_drafts/finalize_service.rb`
  - `cybros/app/services/agent_rpc/session_authorizer.rb`
  - `cybros/app/services/agent_rpc/lifecycle_caller.rb`
  - `cybros/app/services/agent_rpc/callback_dispatcher.rb`
  - `cybros/app/services/agent_rpc/kernel_services/execution_targets.rb`
  - `cybros/app/services/runtime_governance/observability_feed.rb`
- Legacy runtime bootstrap and import still flow through `AgentProgram` + `ExecutionTarget`:
  - `cybros/app/services/agents/bootstrap_bundled_default_service.rb`
  - `cybros/app/services/agent_programs/bootstrap_bundled_default_service.rb`
- Product-facing cleanup is mostly done already; the only remaining app-surface write path is legacy id syncing on conversation creation/update:
  - `cybros/app/controllers/conversations_controller.rb`
  - `cybros/app/services/conversations/runtime_settings_updater.rb`
- Database state still carries legacy runtime tables, columns, foreign keys, and indexes that must be removed before delivery:
  - `cybros/db/schema.rb`
  - `cybros/db/migrate/20260309000006_create_programmable_agent_runtime_state.rb`
  - `cybros/db/migrate/20260311170000_add_runtime_dimensions_to_statistics_tool_call_facts.rb`
  - `cybros/db/migrate/20260313000000_create_agents_and_recognized_deployments.rb`
- Shared test and E2E fixture layers still construct the old runtime model directly, so a dedicated fixture rewrite is required before the final `bin/ci` pass:
  - `cybros/test/test_helper.rb`
  - `cybros/test/e2e/helpers.ts`
  - `cybros/test/e2e/programmable_agent_helpers.ts`
- Technical docs outside `docs/product` still describe `Conversation.agent_program` or `AgentProgram` as the public runtime anchor:
  - `cybros/docs/agent_core/public_api.md`
  - `cybros/docs/agent_core/security.md`
- `docs/product` has already been narrowed substantially; remaining product docs to update are:
  - `cybros/docs/product/README.md`
  - `cybros/docs/product/vision.md`

**Execution Root:** `/Users/jasl/Workspaces/Cybros/cybros/cybros`

**Path Convention:** File lists stay monorepo-relative for grep-ability. Run the shell commands from the Rails app root above, and treat command arguments as app-root-relative even when the matching file bullet is written with a leading `cybros/`.

---

### Task 1: Write The Simplified Runtime Contract Tests

**Files:**
- Create: `cybros/test/integration/agent_runtime_simplification_contract_test.rb`
- Modify: `cybros/test/models/conversation_program_selection_test.rb`
- Modify: `cybros/test/models/run_draft_test.rb`
- Modify: `cybros/test/models/conversation_run_test.rb`

**Step 1: Write the failing test**

Cover:

- a conversation binds to a single public `Agent`
- a turn/run binds to a `RecognizedDeployment`
- changing the backing runtime identity between planning and execution causes drift
- conversations no longer require public execution-target semantics in the happy path

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/agent_runtime_simplification_contract_test.rb test/models/conversation_program_selection_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb`

Expected: FAIL on missing `Agent` and `RecognizedDeployment` bindings, plus outdated deployment-centric assumptions.

**Step 3: Write minimal implementation**

Implement only enough model and service scaffolding to express the simplified runtime contract without yet migrating attachments, workspace, or statistics.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/agent_runtime_simplification_contract_test.rb test/models/conversation_program_selection_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add test/integration/agent_runtime_simplification_contract_test.rb test/models/conversation_program_selection_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb
git commit -m "test: lock simplified agent runtime contract"
```

### Task 2: Add Agent And RecognizedDeployment Data Model Primitives

**Files:**
- Create: `cybros/db/migrate/20260313000000_create_agents_and_recognized_deployments.rb`
- Create: `cybros/app/models/agent.rb`
- Create: `cybros/app/models/recognized_deployment.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/conversation_run.rb`
- Modify: `cybros/app/models/run_draft.rb`
- Modify: `cybros/app/models/automation.rb`
- Create: `cybros/test/models/recognized_deployment_test.rb`
- Create: `cybros/test/models/agent_test.rb`

**Step 1: Write the failing test**

Cover:

- `Agent` stores the user-visible runtime configuration and execution-capacity policy
- `RecognizedDeployment` deduplicates by normalized hard-identity fields
- `Conversation` and `Automation` belong to `Agent`
- `RunDraft` and `ConversationRun` can carry both `recognized_deployment_id` and immutable `recognized_deployment_key`
- `RecognizedDeployment` can be retired without invalidating historical rows

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/agent_test.rb test/models/recognized_deployment_test.rb test/models/conversation_program_selection_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb`

Expected: FAIL because the new tables, associations, and deletion semantics do not exist.

**Step 3: Write minimal implementation**

Implement:

- new `agents` and `recognized_deployments` tables
- `Agent` and `RecognizedDeployment` models
- agent-level execution-capacity fields
- tombstone-friendly deletion fields for recognized deployments
- replacement of core runtime foreign keys on conversations, automations, drafts, and runs where historical integrity must not depend on the dimension row
- defer whole-table deletion of legacy runtime models until Task 15 so the cutover does not leave half-removed schema and routes behind

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/agent_test.rb test/models/recognized_deployment_test.rb test/models/conversation_program_selection_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add db/migrate/20260313000000_create_agents_and_recognized_deployments.rb app/models/agent.rb app/models/recognized_deployment.rb app/models/conversation.rb app/models/conversation_run.rb app/models/run_draft.rb app/models/automation.rb test/models/recognized_deployment_test.rb test/models/agent_test.rb
git commit -m "feat: add agent and recognized deployment models"
```

### Task 3: Replace Conversation, Automation, And Default Bootstrap Bindings With Agent

**Files:**
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/services/conversations/runtime_settings_updater.rb`
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/app/controllers/setups_controller.rb`
- Modify: `cybros/app/models/automation.rb`
- Modify: `cybros/app/services/automations/dispatch.rb`
- Modify: `cybros/app/services/automations/conversation_orchestrator.rb`
- Replace: `cybros/app/services/agent_programs/bootstrap_bundled_default_service.rb`
- Create: `cybros/app/services/agents/bootstrap_bundled_default_service.rb`
- Create: `cybros/test/integration/agent_runtime_binding_cutover_test.rb`

**Step 1: Write the failing test**

Cover:

- conversation creation selects a default `Agent`, not an `AgentProgram`
- first-time setup bootstraps a default `Agent`
- runtime settings updates change `agent_id`, not `agent_program_id` or `default_execution_target_id`
- automation-created conversations bind to `Agent`
- bundled default bootstrap provisions a default `Agent`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/agent_runtime_binding_cutover_test.rb test/integration/setup_and_sessions_test.rb test/services/automations/dispatch_test.rb test/integration/automation_execution_conversation_test.rb test/models/conversation_program_selection_test.rb`

Expected: FAIL because setup, controllers, bootstrap, and automation flows still depend on `AgentProgram` and `ExecutionTarget`.

**Step 3: Write minimal implementation**

Implement:

- agent-based conversation creation and update flows
- agent-based setup bootstrap flow
- agent-based automation dispatch
- replacement of bundled default bootstrap with an `Agent`-centric service
- removal of conversation-level execution-target selection

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/agent_runtime_binding_cutover_test.rb test/integration/setup_and_sessions_test.rb test/services/automations/dispatch_test.rb test/integration/automation_execution_conversation_test.rb test/models/conversation_program_selection_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/models/conversation.rb app/services/conversations/runtime_settings_updater.rb app/controllers/conversations_controller.rb app/controllers/setups_controller.rb app/models/automation.rb app/services/automations/dispatch.rb app/services/automations/conversation_orchestrator.rb app/services/agent_programs/bootstrap_bundled_default_service.rb app/services/agents/bootstrap_bundled_default_service.rb test/integration/agent_runtime_binding_cutover_test.rb
git commit -m "feat: cut over conversations and automations to agents"
```

### Task 4: Replace Execution-Target Governance With Agent-Level Execution Capacity

**Files:**
- Modify: `cybros/app/services/runtime_governance/draft_governor_resolver.rb`
- Modify: `cybros/app/services/runtime_governance/execution_capacity_resolver.rb`
- Modify: `cybros/app/services/runtime_governance/execution_capacity_enforcer.rb`
- Modify: `cybros/app/services/runtime_governance/execution_capacity_leases.rb`
- Modify: `cybros/app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `cybros/app/services/run_drafts/finalize_service.rb`
- Modify: `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb`
- Modify: `cybros/test/services/runtime_governance/execution_capacity_leases_test.rb`
- Modify: `cybros/test/models/run_draft_test.rb`
- Modify: `cybros/test/integration/execution_capacity_enforcement_test.rb`
- Modify: `cybros/test/integration/run_draft_finalization_test.rb`
- Create: `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb`
- Create: `cybros/test/integration/agent_execution_capacity_test.rb`

**Step 1: Write the failing test**

Cover:

- planning resolves execution capacity from `Agent`
- planning no longer requires `ExecutionTarget`
- execution-capacity runtime governors and leases still work with the new policy anchor
- conversation runs snapshot agent-level capacity policy rather than execution-target ids

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/runtime_governance/execution_capacity_resolver_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/models/run_draft_test.rb test/integration/run_draft_finalization_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/agent_execution_capacity_test.rb`

Expected: FAIL because runtime governance still requires `ExecutionTarget`.

**Step 3: Write minimal implementation**

Implement:

- agent-level execution-capacity resolution
- removal of execution-target requirement from draft planning
- updated runtime-governor snapshots keyed to the new policy anchor

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/runtime_governance/execution_capacity_resolver_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/models/run_draft_test.rb test/integration/run_draft_finalization_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/agent_execution_capacity_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/runtime_governance/draft_governor_resolver.rb app/services/runtime_governance/execution_capacity_resolver.rb app/services/runtime_governance/execution_capacity_enforcer.rb app/services/runtime_governance/execution_capacity_leases.rb app/services/run_drafts/conversation_turn_planning_service.rb app/services/run_drafts/finalize_service.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/models/run_draft_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/run_draft_finalization_test.rb test/services/runtime_governance/execution_capacity_resolver_test.rb test/integration/agent_execution_capacity_test.rb
git commit -m "feat: move execution capacity to agents"
```

### Task 5: Resolve RecognizedDeployment From Runtime Handshakes

**Files:**
- Create: `cybros/lib/cybros/programmable_agent/recognized_deployment_resolver.rb`
- Modify: `cybros/app/services/agent_rpc/session_authorizer.rb`
- Modify: `cybros/lib/cybros/programmable_agent/capability_handshake.rb`
- Modify: `cybros/app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `cybros/app/services/run_drafts/finalize_service.rb`
- Create: `cybros/test/lib/cybros/programmable_agent/recognized_deployment_resolver_test.rb`
- Modify: `cybros/test/models/run_draft_test.rb`
- Modify: `cybros/test/models/conversation_run_test.rb`

**Step 1: Write the failing test**

Cover:

- `initialize` and capability handshake data are normalized into one recognized runtime identity
- the same runtime identity reuses the same `RecognizedDeployment`
- changed hard-identity fields create a new `RecognizedDeployment`
- planning and finalized runs capture `recognized_deployment_id` and `recognized_deployment_key`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/programmable_agent/recognized_deployment_resolver_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb`

Expected: FAIL because no recognized-deployment resolver exists and planning/finalization still pin only mutable deployment state.

**Step 3: Write minimal implementation**

Implement:

- a resolver that builds a normalized hard-identity payload
- digest/key generation
- recognized-deployment lookup or creation
- propagation into run-draft and conversation-run persistence

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/programmable_agent/recognized_deployment_resolver_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add lib/cybros/programmable_agent/recognized_deployment_resolver.rb app/services/agent_rpc/session_authorizer.rb lib/cybros/programmable_agent/capability_handshake.rb app/services/run_drafts/conversation_turn_planning_service.rb app/services/run_drafts/finalize_service.rb test/lib/cybros/programmable_agent/recognized_deployment_resolver_test.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb
git commit -m "feat: resolve recognized deployments from handshakes"
```

### Task 6: Rewrite Agent RPC Runtime State Around Agent And RecognizedDeployment

**Files:**
- Modify: `cybros/app/models/agent_rpc_session.rb`
- Modify: `cybros/app/models/agent_rpc_invocation.rb`
- Modify: `cybros/app/services/agent_rpc/lifecycle_caller.rb`
- Modify: `cybros/app/services/agent_rpc/invocation_store.rb`
- Modify: `cybros/app/services/agent_rpc/session_authorizer.rb`
- Replace: `cybros/app/services/agent_deployments/rpc_client.rb`
- Create: `cybros/app/services/agents/rpc_client.rb`
- Create: `cybros/db/migrate/20260313000001_rewrite_agent_rpc_runtime_state.rb`
- Create: `cybros/test/integration/agent_rpc_runtime_state_cutover_test.rb`

**Step 1: Write the failing test**

Cover:

- agent RPC sessions and invocations no longer require `agent_program_id` / `agent_deployment_id`
- runtime state binds to `agent_id`, `recognized_deployment_id`, and immutable recognized-deployment keys
- replay and uniqueness constraints still work after the cutover

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/agent_rpc_runtime_state_cutover_test.rb`

Expected: FAIL because current runtime state tables and services are still deployment-centric.

**Step 3: Write minimal implementation**

Implement:

- schema rewrite for runtime state tables
- new binding invariants for session and invocation persistence
- replay-key updates based on the new runtime identity model
- agent-bound RPC client routing under an `Agents::*` namespace instead of continuing to deepen `AgentDeployments::*` coupling

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/agent_rpc_runtime_state_cutover_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/models/agent_rpc_session.rb app/models/agent_rpc_invocation.rb app/services/agent_rpc/lifecycle_caller.rb app/services/agent_rpc/invocation_store.rb app/services/agent_rpc/session_authorizer.rb app/services/agent_deployments/rpc_client.rb app/services/agents/rpc_client.rb db/migrate/20260313000001_rewrite_agent_rpc_runtime_state.rb test/integration/agent_rpc_runtime_state_cutover_test.rb
git commit -m "feat: rewrite agent rpc runtime state"
```

### Task 7: Enforce Turn-Level Drift Detection

**Files:**
- Modify: `cybros/app/services/agent_rpc/session_authorizer.rb`
- Modify: `cybros/app/services/agent_rpc/lifecycle_caller.rb`
- Modify: `cybros/app/services/agent_rpc/invocation_store.rb`
- Modify: `cybros/app/models/agent_rpc_session.rb`
- Modify: `cybros/app/models/agent_rpc_invocation.rb`
- Create: `cybros/test/integration/recognized_deployment_drift_test.rb`

**Step 1: Write the failing test**

Cover:

- a turn continues when later RPC calls match the original recognized deployment
- a turn is marked drifted/stale when later calls resolve to a different recognized deployment
- Cybros does not silently continue execution after recognized-deployment drift

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/recognized_deployment_drift_test.rb`

Expected: FAIL because lifecycle RPC still lacks recognized-deployment drift semantics.

**Step 3: Write minimal implementation**

Implement:

- recognized-deployment comparison during later lifecycle calls
- drift error classification
- turn invalidation or stale marking
- replay-safe persistence of drift failures

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/recognized_deployment_drift_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agent_rpc/session_authorizer.rb app/services/agent_rpc/lifecycle_caller.rb app/services/agent_rpc/invocation_store.rb app/models/agent_rpc_session.rb app/models/agent_rpc_invocation.rb test/integration/recognized_deployment_drift_test.rb
git commit -m "feat: enforce recognized deployment drift detection"
```

### Task 8: Introduce Conversation-Owned Logical Workspace

**Files:**
- Create: `cybros/db/migrate/20260313000002_add_conversation_workspace_fields.rb`
- Modify: `cybros/app/models/conversation.rb`
- Create: `cybros/app/services/conversations/workspace_initializer.rb`
- Modify: `cybros/app/services/conversations/bootstrap_hook_dispatcher.rb`
- Modify: `cybros/app/models/runtime_setting.rb`
- Create: `cybros/test/services/conversations/workspace_initializer_test.rb`
- Create: `cybros/test/integration/conversation_bootstrap_dispatch_test.rb`

**Step 1: Write the failing test**

Cover:

- conversations own one logical workspace identity
- the workspace is lazily initialized on the main lane first-user-message path
- empty conversations do not allocate workspace materialization
- the workspace remains persistent across future turns

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/conversations/workspace_initializer_test.rb test/integration/conversation_bootstrap_dispatch_test.rb`

Expected: FAIL because conversation-owned workspace initialization does not yet exist.

**Step 3: Write minimal implementation**

Implement:

- conversation workspace metadata fields
- lazy initialization service
- integration with the already approved bootstrap hook timing
- default local host-path derivation behind runtime settings

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/conversations/workspace_initializer_test.rb test/integration/conversation_bootstrap_dispatch_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add db/migrate/20260313000002_add_conversation_workspace_fields.rb app/models/conversation.rb app/services/conversations/workspace_initializer.rb app/services/conversations/bootstrap_hook_dispatcher.rb app/models/runtime_setting.rb test/services/conversations/workspace_initializer_test.rb test/integration/conversation_bootstrap_dispatch_test.rb
git commit -m "feat: add conversation owned workspace"
```

### Task 9: Add Attachment Manifest And Upload Capability Gate

**Files:**
- Create: `cybros/db/migrate/20260313000003_create_conversation_attachments.rb`
- Create: `cybros/app/models/conversation_attachment.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/messages/user_message.rb`
- Create: `cybros/app/services/conversations/attachment_manifest_builder.rb`
- Create: `cybros/test/models/conversation_attachment_test.rb`
- Create: `cybros/test/services/conversations/attachment_manifest_builder_test.rb`
- Create: `cybros/test/integration/conversation_attachment_upload_gate_test.rb`

**Step 1: Write the failing test**

Cover:

- uploaded files are persisted in Active Storage and represented in ordered conversation attachment rows
- attachment ordering is stable
- sending attachments to an agent without upload capability is rejected
- manifest metadata includes filename, type, size, digest, and source message binding

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/conversation_attachment_test.rb test/services/conversations/attachment_manifest_builder_test.rb test/integration/conversation_attachment_upload_gate_test.rb`

Expected: FAIL because no conversation attachment manifest or upload capability gate exists.

**Step 3: Write minimal implementation**

Implement:

- attachment rows backed by Active Storage blobs
- manifest ordering and normalization
- capability validation against the current agent/runtime path
- message rejection when upload is unsupported

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/conversation_attachment_test.rb test/services/conversations/attachment_manifest_builder_test.rb test/integration/conversation_attachment_upload_gate_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add db/migrate/20260313000003_create_conversation_attachments.rb app/models/conversation_attachment.rb app/models/conversation.rb app/models/messages/user_message.rb app/services/conversations/attachment_manifest_builder.rb test/models/conversation_attachment_test.rb test/services/conversations/attachment_manifest_builder_test.rb test/integration/conversation_attachment_upload_gate_test.rb
git commit -m "feat: add conversation attachment manifest"
```

### Task 10: Add Attachment Import Protocol To Agent RPC

**Files:**
- Modify: `cybros/docs/product/agent_rpc.md`
- Replace: `cybros/app/services/agent_deployments.rb`
- Create: `cybros/app/services/agents/protocol.rb`
- Modify: `cybros/lib/cybros/programmable_agent_fixture.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/application.rb`
- Modify: `cybros/agents/default/test/support/callback_harness.rb`
- Modify: `cybros/agents/default/test/integration/rpc_contract_test.rb`
- Modify: `cybros/agents/default/test/unit/manifest_test.rb`
- Create: `cybros/test/integration/attachment_import_protocol_test.rb`

**Step 1: Write the failing test**

Cover:

- the protocol exposes `attachments.import`
- agents that advertise upload can handle descriptor-based imports
- descriptor payloads use signed URLs rather than raw bytes
- the bundled/default agent fixture and contract tests enforce the new method

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/attachment_import_protocol_test.rb agents/default/test/integration/rpc_contract_test.rb agents/default/test/unit/manifest_test.rb`

Expected: FAIL because no attachment import RPC contract exists.

**Step 3: Write minimal implementation**

Implement:

- `attachments.import` protocol docs and required-method handling under an `Agents::Protocol` contract module
- signed-URL descriptor contract
- fixture/default-agent support for the new method
- default-agent manifest and callback test support updates

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/attachment_import_protocol_test.rb agents/default/test/integration/rpc_contract_test.rb agents/default/test/unit/manifest_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add docs/product/agent_rpc.md app/services/agent_deployments.rb app/services/agents/protocol.rb lib/cybros/programmable_agent_fixture.rb agents/default/lib/cybros/agents/default/application.rb agents/default/test/support/callback_harness.rb agents/default/test/integration/rpc_contract_test.rb agents/default/test/unit/manifest_test.rb test/integration/attachment_import_protocol_test.rb
git commit -m "feat: add attachment import protocol"
```

### Task 11: Implement Attachment Transfer Tasks And Default Workspace Materialization

**Files:**
- Create: `cybros/lib/cybros/attachments/tools.rb`
- Modify: `cybros/lib/cybros/programmable_agent/kernel_capability_catalog.rb`
- Modify: `cybros/lib/cybros/programmable_agent/hook_action_executor.rb`
- Create: `cybros/app/services/conversations/attachment_transfer_service.rb`
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Create: `cybros/test/integration/default_agent_attachment_transfer_test.rb`
- Create: `cybros/test/integration/external_agent_attachment_transfer_test.rb`

**Step 1: Write the failing test**

Cover:

- the default local agent receives transferred attachments inside the conversation workspace
- external agents receive `attachments.import` calls and return remote refs
- transfer failure leaves the Active Storage source intact and surfaces a retriable failure
- attachment transfer is explicit and auditable

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb`

Expected: FAIL because no attachment transfer task or service exists.

**Step 3: Write minimal implementation**

Implement:

- explicit transfer-task wiring
- default local materialization into conversation workspace
- external agent `attachments.import` integration
- remote reference recording

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add lib/cybros/attachments/tools.rb lib/cybros/programmable_agent/kernel_capability_catalog.rb lib/cybros/programmable_agent/hook_action_executor.rb app/services/conversations/attachment_transfer_service.rb lib/cybros/agent_runtime_resolver.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb
git commit -m "feat: add attachment transfer tasks"
```

### Task 12: Inject Attachment And Workspace Context Into Planning And Runtime Hooks

**Files:**
- Modify: `cybros/app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `cybros/lib/cybros/programmable_agent_provider.rb`
- Modify: `cybros/lib/cybros/programmable_agent/session_context.rb`
- Modify: `cybros/lib/cybros/programmable_agent/execution_context.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/hooks/before_agent_step.rb`
- Modify: `cybros/agents/default/test/support/callback_harness.rb`
- Modify: `cybros/agents/default/test/integration/rpc_contract_test.rb`
- Create: `cybros/test/integration/attachment_prompt_injection_test.rb`

**Step 1: Write the failing test**

Cover:

- planning payload includes the ordered attachment manifest
- runtime hooks receive workspace descriptor data
- multimodal-capable image inputs are injected with stable numbering
- non-image attachments are referenced without dumping full contents into the prompt
- the default bundled agent consumes workspace/attachment descriptors instead of relying on `execution_target.*` callback methods

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/attachment_prompt_injection_test.rb agents/default/test/integration/rpc_contract_test.rb`

Expected: FAIL because planning/runtime payloads do not yet expose the new attachment and workspace descriptors.

**Step 3: Write minimal implementation**

Implement:

- attachment manifest injection into planning and runtime contexts
- workspace descriptor propagation
- image-input attachment plumbing where the current model path supports it
- removal of `execution_target.*` callback assumptions from the default bundled agent path

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/attachment_prompt_injection_test.rb agents/default/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/run_drafts/conversation_turn_planning_service.rb lib/cybros/programmable_agent_provider.rb lib/cybros/programmable_agent/session_context.rb lib/cybros/programmable_agent/execution_context.rb agents/default/lib/cybros/agents/default/hooks/before_agent_step.rb agents/default/test/support/callback_harness.rb agents/default/test/integration/rpc_contract_test.rb test/integration/attachment_prompt_injection_test.rb
git commit -m "feat: inject attachment and workspace context"
```

### Task 13: Move Statistics To RecognizedDeployment Keys And Remove Live AgentProgram Dimensions

**Files:**
- Create: `cybros/db/migrate/20260313000004_add_recognized_deployment_dimensions_to_statistics.rb`
- Modify: `cybros/app/models/statistics/tool_call_fact.rb`
- Modify: `cybros/app/services/statistics/tool_call_fact_projector.rb`
- Modify: `cybros/lib/cybros/statistics/tool_reliability_stats.rb`
- Modify: `cybros/test/models/statistics/tool_call_fact_test.rb`
- Modify: `cybros/test/models/statistics/tool_call_fact_projector_test.rb`
- Modify: `cybros/test/lib/cybros/statistics/tool_reliability_stats_test.rb`
- Create: `cybros/test/integration/recognized_deployment_statistics_test.rb`

**Step 1: Write the failing test**

Cover:

- tool-call stats persist `recognized_deployment_key`
- stats continue to aggregate correctly when a recognized deployment is retired
- nullable `recognized_deployment_id` can still be used for convenience joins
- runtime identity dimensions appear in reliability and debugging outputs
- statistics no longer depend on live `agent_program_id` / `agent_program_version` foreign-key semantics

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/statistics/tool_call_fact_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/cybros/statistics/tool_reliability_stats_test.rb test/integration/recognized_deployment_statistics_test.rb`

Expected: FAIL because statistics do not yet project recognized-deployment dimensions.

**Step 3: Write minimal implementation**

Implement:

- statistics schema rewrite so recognized-deployment fields become the durable runtime identity and stale agent-program dimensions stop being required for runtime reporting
- projector updates to derive recognized deployment identity from the upstream conversation run rather than `conversation.agent_program`
- reliability/debug aggregation updates so reporting keys off `agent_id` plus `recognized_deployment_key`, not `agent_program_version`
- null-safe behavior when the dimension row is retired or missing

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/statistics/tool_call_fact_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/cybros/statistics/tool_reliability_stats_test.rb test/integration/recognized_deployment_statistics_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add db/migrate/20260313000004_add_recognized_deployment_dimensions_to_statistics.rb app/models/statistics/tool_call_fact.rb app/services/statistics/tool_call_fact_projector.rb lib/cybros/statistics/tool_reliability_stats.rb test/models/statistics/tool_call_fact_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/cybros/statistics/tool_reliability_stats_test.rb test/integration/recognized_deployment_statistics_test.rb
git commit -m "feat: key runtime stats by recognized deployment"
```

### Task 14: Cut Over Dashboard And Agent Entry Flow

**Files:**
- Modify: `cybros/app/controllers/dashboard_controller.rb`
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/app/views/dashboard/show.html.erb`
- Modify: `cybros/app/views/conversations/index.html.erb`
- Modify: `cybros/app/views/layouts/agent/_sidebar.html.erb`
- Modify: `cybros/test/integration/dashboard_test.rb`
- Modify: `cybros/test/integration/conversations_test.rb`
- Modify: `cybros/test/integration/conversation_branching_test.rb`
- Modify: `cybros/test/e2e/helpers.ts`
- Modify: `cybros/test/e2e/dashboard.spec.ts`
- Modify: `cybros/test/e2e/conversations.spec.ts`
- Modify: `cybros/test/e2e/responsive_shell.spec.ts`

**Step 1: Write the failing test**

Cover:

- Dashboard lists all selectable `Agent` records and exposes a per-agent `New conversation` action
- generic `New chat` / `New conversation` affordances disappear from the dashboard, sidebar shell, and conversations index
- conversation creation requires an explicit `agent_id`
- branching still inherits the parent conversation agent without reopening agent selection
- shared E2E helpers create conversations through the dashboard agent launcher instead of a generic conversations form

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/dashboard_test.rb test/integration/conversations_test.rb test/integration/conversation_branching_test.rb`

Run: `RAILS_ENV=development bin/ci_e2e test/e2e/dashboard.spec.ts test/e2e/conversations.spec.ts test/e2e/responsive_shell.spec.ts`

Expected: FAIL because the product still exposes generic conversation creation paths and the dashboard does not yet act as the agent launcher.

**Step 3: Write minimal implementation**

Implement:

- dashboard agent listing with per-agent creation actions
- explicit `agent_id` handling in conversation creation
- removal of shell-level generic new-conversation controls
- helper and spec updates so E2E flows launch conversations from the selected agent

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/dashboard_test.rb test/integration/conversations_test.rb test/integration/conversation_branching_test.rb`

Run: `RAILS_ENV=development bin/ci_e2e test/e2e/dashboard.spec.ts test/e2e/conversations.spec.ts test/e2e/responsive_shell.spec.ts`

Expected: PASS

**Step 5: Commit**

```bash
git add app/controllers/dashboard_controller.rb app/controllers/conversations_controller.rb app/views/dashboard/show.html.erb app/views/conversations/index.html.erb app/views/layouts/agent/_sidebar.html.erb test/integration/dashboard_test.rb test/integration/conversations_test.rb test/integration/conversation_branching_test.rb test/e2e/helpers.ts test/e2e/dashboard.spec.ts test/e2e/conversations.spec.ts test/e2e/responsive_shell.spec.ts
git commit -m "feat: launch conversations from dashboard agents"
```

### Task 15: Remove Legacy Binding Adapters From Conversation And Automation Entrypoints

**Files:**
- Create: `cybros/db/migrate/20260313000005_relax_legacy_runtime_entrypoint_columns.rb`
- Modify: `cybros/db/schema.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/automation.rb`
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/app/services/conversations/runtime_settings_updater.rb`
- Modify: `cybros/app/services/automations/dispatch.rb`
- Modify: `cybros/test/integration/agent_runtime_binding_cutover_test.rb`
- Modify: `cybros/test/integration/conversations_test.rb`
- Modify: `cybros/test/integration/automation_execution_conversation_test.rb`
- Modify: `cybros/test/models/conversation_program_selection_test.rb`

Scope note:

- This task removes write-time dependence on legacy conversation/automation ids and relaxes the schema so those ids can be null.
- Read-time adapter helpers such as `Conversation#agent_program` and `Automation#execution_target` stay in place until later cleanup tasks, because live runtime/planning code still reads them today.

**Step 1: Write the failing tests**

Cover:

- `Conversation` and `Automation` validate and persist on `agent_id` alone
- conversation creation/update flows no longer write `agent_program_id` or `default_execution_target_id`
- branch and automation-dispatch entrypoints also stop copying legacy ids
- legacy conversation/automation columns are nullable so agent-only entrypoints can persist before final schema deletion
- dashboard/conversation launcher flows still create valid conversations after those adapter removals

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/agent_runtime_binding_cutover_test.rb test/integration/conversations_test.rb test/integration/automation_execution_conversation_test.rb test/models/conversation_program_selection_test.rb`

Expected: FAIL because conversation and automation entrypoints still sync or validate legacy runtime ids, and the database still requires legacy columns on `conversations` / `automations`.

**Step 3: Write minimal implementation**

Implement:

- add the migration that relaxes `conversations.agent_program_id`, `automations.agent_program_id`, and `automations.execution_target_id`
- stop syncing legacy ids in controller/update paths
- stop copying legacy ids during branch creation and automation dispatch
- clear stale conversation legacy ids when agent selection changes
- make `agent_id` the only user-facing runtime binding on new or updated entrypoints
- remove automation-side legacy presence validation/defaulting that blocks agent-only persistence
- update tests to assert agent-only semantics while tolerating temporary read adapters

**Step 4: Run verification**

Run: `bin/rails test test/integration/agent_runtime_binding_cutover_test.rb test/integration/conversations_test.rb test/integration/automation_execution_conversation_test.rb test/models/conversation_program_selection_test.rb`

Run: `bin/rails db:migrate`

Run: `RAILS_ENV=test bin/rails db:migrate`

Run: `rg -n "(agent_program_id|default_execution_target_id|execution_target_id)" app/controllers/conversations_controller.rb app/services/conversations/runtime_settings_updater.rb app/services/automations/dispatch.rb app/models/conversation.rb app/models/automation.rb`

Expected: PASS for tests and migrations, and the grep should show no remaining conversation/automation entrypoint writes that copy legacy runtime ids.

**Step 5: Commit**

```bash
git add db/migrate/20260313000005_relax_legacy_runtime_entrypoint_columns.rb db/schema.rb app/models/conversation.rb app/models/automation.rb app/controllers/conversations_controller.rb app/services/conversations/runtime_settings_updater.rb app/services/automations/dispatch.rb test/integration/agent_runtime_binding_cutover_test.rb test/integration/conversations_test.rb test/integration/automation_execution_conversation_test.rb test/models/conversation_program_selection_test.rb
git commit -m "refactor: remove conversation runtime legacy adapters"
```

### Task 16: Remove Legacy Binding Adapters From Drafts And Runs

**Files:**
- Create: `cybros/db/migrate/20260313150000_relax_legacy_runtime_snapshot_columns.rb`
- Modify: `cybros/app/models/run_draft.rb`
- Modify: `cybros/app/models/conversation_run.rb`
- Modify: `cybros/app/models/concerns/runtime_governor_snapshot_consistency.rb`
- Modify: `cybros/app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `cybros/app/services/run_drafts/finalize_service.rb`
- Modify: `cybros/test/models/run_draft_test.rb`
- Modify: `cybros/test/models/conversation_run_test.rb`
- Modify: `cybros/test/integration/run_draft_finalization_test.rb`
- Modify: `cybros/test/integration/execution_capacity_enforcement_test.rb`
- Modify: `cybros/test/integration/recognized_deployment_drift_test.rb`

**Step 1: Write the failing tests**

Cover:

- `RunDraft` and `ConversationRun` no longer expose or validate `agent_program_id`, `agent_deployment_id`, or `execution_target_id`
- planning/finalization persist only `agent_id`, recognized deployment data, fingerprints, and runtime governors
- stale/upgrade/drift behavior still works through `RecognizedDeployment`
- execution-capacity snapshots remain agent-scoped after legacy columns are removed from draft/run logic

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/run_draft_test.rb test/models/conversation_run_test.rb test/integration/run_draft_finalization_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/recognized_deployment_drift_test.rb`

Expected: FAIL because draft/run persistence and stale checks still depend on legacy runtime ids.

**Step 3: Write minimal implementation**

- first relax the still-live `run_drafts.agent_program_id`, `run_drafts.agent_deployment_id`, `conversation_runs.agent_program_id`, and `conversation_runs.agent_deployment_id` `NOT NULL` constraints so the breaking cutover can stop writing them before Task 19 drops them entirely
- remove legacy adapter accessors and validations from draft/run models
- update planning and finalization to stop writing legacy ids
- keep drift detection and historical pinning entirely on `agent_id` + recognized deployment data
- update tests and fixtures to assert the new row shape directly

**Step 4: Run verification**

Run: `bin/rails test test/models/run_draft_test.rb test/models/conversation_run_test.rb test/integration/run_draft_finalization_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/recognized_deployment_drift_test.rb`

Run: `rg -n "(agent_program_id|agent_deployment_id|execution_target_id|proposed_execution_target_id)" app/models/run_draft.rb app/models/conversation_run.rb app/services/run_drafts/conversation_turn_planning_service.rb app/services/run_drafts/finalize_service.rb`

Expected: PASS for tests, and grep should show no remaining active draft/run binding logic on legacy ids.

**Step 5: Commit**

```bash
git add app/models/run_draft.rb app/models/conversation_run.rb app/models/concerns/runtime_governor_snapshot_consistency.rb app/services/run_drafts/conversation_turn_planning_service.rb app/services/run_drafts/finalize_service.rb test/models/run_draft_test.rb test/models/conversation_run_test.rb test/integration/run_draft_finalization_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/recognized_deployment_drift_test.rb
git commit -m "refactor: remove draft runtime legacy adapters"
```

### Task 17: Replace Legacy Runtime Resolution And Remove `execution_target.*` Kernel Surface

**Files:**
- Modify: `cybros/app/models/agent.rb`
- Modify: `cybros/app/models/recognized_deployment.rb`
- Modify: `cybros/app/models/agent_rpc_session.rb`
- Modify: `cybros/app/models/agent_rpc_invocation.rb`
- Modify: `cybros/app/services/agent_rpc/session_authorizer.rb`
- Modify: `cybros/app/services/agent_rpc/lifecycle_caller.rb`
- Modify: `cybros/app/services/agent_rpc/callback_dispatcher.rb`
- Delete: `cybros/app/services/agent_rpc/kernel_services/execution_targets.rb`
- Delete: `cybros/app/services/runtime_governance/execution_target_inventory.rb`
- Delete: `cybros/app/services/runtime_governance/execution_target_switch_policy.rb`
- Modify: `cybros/app/services/runtime_governance/observability_feed.rb`
- Modify: `cybros/app/services/agents/bootstrap_bundled_default_service.rb`
- Modify: `cybros/test/integration/agent_rpc_session_auth_test.rb`
- Modify: `cybros/test/integration/recognized_deployment_drift_test.rb`
- Modify: `cybros/test/integration/agent_upgrade_conversation_binding_test.rb`
- Modify: `cybros/test/integration/runtime_governance_observability_test.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_test.rb`

**Step 1: Write the failing tests**

Cover:

- `Agent` resolves live runtime from agent-owned config rather than `legacy_agent_program`
- RPC sessions and invocations bind through `agent_id` plus `recognized_deployment_id`
- callback dispatch no longer exposes `execution_target.list/get`
- observability labels and owner resolution stop emitting `ExecutionTarget`, `ExecutionLocation`, and `AgentDeployment` as live nouns

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/agent_rpc_session_auth_test.rb test/integration/recognized_deployment_drift_test.rb test/integration/agent_upgrade_conversation_binding_test.rb test/integration/runtime_governance_observability_test.rb test/lib/cybros/agent_runtime_resolver_test.rb`

Expected: FAIL because runtime resolution still depends on legacy program/deployment/target objects.

**Step 3: Write minimal implementation**

Implement:

- move agent runtime resolution onto agent-owned configuration
- remove `execution_target.*` callback handling and related kernel service code
- replace observability subject/owner mapping with `Agent` and `RecognizedDeployment`
- keep bootstrap/test runtime working through the new agent-owned runtime source
- keep the underlying `agents.legacy_*` / `recognized_deployments.legacy_agent_deployment_id` storage columns until Task 19, but stop using those names as the live runtime-resolution or callback surface in this task

**Step 4: Run verification**

Run: `bin/rails test test/integration/agent_rpc_session_auth_test.rb test/integration/recognized_deployment_drift_test.rb test/integration/agent_upgrade_conversation_binding_test.rb test/integration/runtime_governance_observability_test.rb test/lib/cybros/agent_runtime_resolver_test.rb`

Run: `rg -n "(execution_target\\.|ExecutionTargetInventory|ExecutionTargetSwitchPolicy|AgentDeployment)" app/services/agent_rpc app/services/runtime_governance app/models/agent_rpc_session.rb app/models/agent_rpc_invocation.rb app/models/recognized_deployment.rb`

Expected: PASS for tests, and grep should show no live callback/runtime-resolution dependency on the deleted kernel surface or deployment-centric callback/runtime APIs. The raw legacy storage columns on `Agent` remain until Task 19.

**Step 5: Commit**

```bash
git add app/models/agent.rb app/models/recognized_deployment.rb app/models/agent_rpc_session.rb app/models/agent_rpc_invocation.rb app/services/agent_rpc/session_authorizer.rb app/services/agent_rpc/lifecycle_caller.rb app/services/agent_rpc/callback_dispatcher.rb app/services/runtime_governance/observability_feed.rb app/services/agents/bootstrap_bundled_default_service.rb test/integration/agent_rpc_session_auth_test.rb test/integration/recognized_deployment_drift_test.rb test/integration/agent_upgrade_conversation_binding_test.rb test/integration/runtime_governance_observability_test.rb test/lib/cybros/agent_runtime_resolver_test.rb
git add -A app/services/agent_rpc/kernel_services/execution_targets.rb app/services/runtime_governance/execution_target_inventory.rb app/services/runtime_governance/execution_target_switch_policy.rb
git commit -m "refactor: remove legacy runtime kernel surfaces"
```

### Task 18: Rewrite Shared Test And E2E Fixtures Off The Legacy Runtime Model

**Files:**
- Modify: `cybros/test/test_helper.rb`
- Modify: `cybros/test/e2e/helpers.ts`
- Modify: `cybros/test/e2e/programmable_agent_helpers.ts`
- Modify: `cybros/test/services/automations/execution_state_recorder_test.rb`
- Modify: `cybros/test/services/runtime_governance/runtime_waits_test.rb`
- Modify: `cybros/test/system/system_settings_automations_test.rb`
- Modify: `cybros/test/system/system_settings_runtime_governance_test.rb`
- Modify: `cybros/test/integration/agent_rpc_session_auth_test.rb`
- Modify: `cybros/test/integration/default_agent_attachment_transfer_test.rb`
- Modify: `cybros/test/integration/external_agent_attachment_transfer_test.rb`
- Modify: `cybros/test/integration/programmable_agent_execution_test.rb`
- Modify: `cybros/test/integration/programmable_agent_hooks_test.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/hook_action_executor_test.rb`

**Step 1: Write the failing checklist and audits**

Cover:

- shared test helpers no longer seed `AgentProgram`, `AgentDeployment`, `ExecutionTarget`, `ExecutionLocation`, or infrastructure `Workspace`
- programmable-agent fixture helpers create `Agent` plus `RecognizedDeployment` directly and expose the new runtime vocabulary
- attachment, automation, runtime governance, and RPC suites assert the simplified runtime contract instead of legacy ids
- the remaining targeted suites are sufficient to support a final full `bin/ci` / `bin/ci_e2e` pass after schema cleanup

**Step 2: Run audits to expose the current mismatch**

Run: `rg -n "(AgentProgram|AgentDeployment|ExecutionTarget|ExecutionLocation|\\bWorkspace\\b|legacy_agent_program|legacy_execution_target|agent_program_id|agent_deployment_id|default_execution_target_id|execution_target\\.)" test/test_helper.rb test/e2e test/services test/system test/integration test/lib`

Run: `bin/rails test test/services/automations/execution_state_recorder_test.rb test/services/runtime_governance/runtime_waits_test.rb test/system/system_settings_automations_test.rb test/system/system_settings_runtime_governance_test.rb test/integration/agent_rpc_session_auth_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb test/integration/programmable_agent_execution_test.rb test/integration/programmable_agent_hooks_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb`

Expected: FAIL with helper-level legacy runtime construction and assertions still present.

**Step 3: Write minimal implementation**

Implement:

- rewrite shared Ruby and Playwright helpers around `Agent`, `RecognizedDeployment`, logical workspace, and agent-owned execution capacity
- delete helper APIs whose only purpose was creating or querying `AgentProgram` / `ExecutionTarget`
- convert the listed suites so they assert the new runtime contract directly
- use the audit grep from Step 2 to mop up any additional targeted helper or fixture files revealed during conversion

**Step 4: Run verification**

Run: `bin/rails test test/services/automations/execution_state_recorder_test.rb test/services/runtime_governance/runtime_waits_test.rb test/system/system_settings_automations_test.rb test/system/system_settings_runtime_governance_test.rb test/integration/agent_rpc_session_auth_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb test/integration/programmable_agent_execution_test.rb test/integration/programmable_agent_hooks_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb`

Run: `RAILS_ENV=development bin/ci_e2e test/e2e/bootstrap_hooks.spec.ts test/e2e/bundled_default_agent_flow.spec.ts test/e2e/programmable_agent_approval_resume.spec.ts`

Run: `rg -n "(AgentProgram|AgentDeployment|ExecutionTarget|ExecutionLocation|\\bWorkspace\\b|legacy_agent_program|legacy_execution_target|agent_program_id|agent_deployment_id|default_execution_target_id|execution_target\\.)" test/test_helper.rb test/e2e test/services test/system test/integration test/lib`

Expected: PASS for the targeted test suites, and the grep should only hit intentionally historical archived tests or explicit compatibility assertions scheduled for Task 19 deletion.

**Step 5: Commit**

```bash
git add test/test_helper.rb test/e2e/helpers.ts test/e2e/programmable_agent_helpers.ts test/services/automations/execution_state_recorder_test.rb test/services/runtime_governance/runtime_waits_test.rb test/system/system_settings_automations_test.rb test/system/system_settings_runtime_governance_test.rb test/integration/agent_rpc_session_auth_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb test/integration/programmable_agent_execution_test.rb test/integration/programmable_agent_hooks_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb
git commit -m "test: rewrite runtime fixtures for agent cutover"
```

### Task 19A: Move Runtime Transport Ownership Onto Agent

**Files:**
- Modify: `cybros/app/models/agent.rb`
- Modify: `cybros/app/models/recognized_deployment.rb`
- Modify: `cybros/app/services/agents/bootstrap_bundled_default_service.rb`
- Modify: `cybros/app/services/agents/rpc_client.rb`
- Modify: `cybros/app/services/agent_rpc/session_authorizer.rb`
- Modify: `cybros/app/services/agent_rpc/lifecycle_caller.rb`
- Modify: `cybros/app/services/conversations/attachment_transfer_service.rb`
- Modify: `cybros/app/services/conversations/bootstrap_hook_dispatcher.rb`
- Modify: `cybros/app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `cybros/app/services/run_drafts/finalize_service.rb`
- Modify: `cybros/lib/cybros/programmable_agent/recognized_deployment_resolver.rb`
- Create: `cybros/db/migrate/20260313170000_move_runtime_transport_configuration_to_agents.rb`
- Modify: `cybros/db/schema.rb`
- Modify: `cybros/test/models/agent_test.rb`
- Modify: `cybros/test/models/recognized_deployment_test.rb`
- Modify: `cybros/test/services/agent_rpc/lifecycle_caller_test.rb`
- Modify: `cybros/test/integration/agent_rpc_session_auth_test.rb`
- Modify: `cybros/test/integration/default_agent_attachment_transfer_test.rb`
- Modify: `cybros/test/integration/external_agent_attachment_transfer_test.rb`
- Modify: `cybros/test/integration/recognized_deployment_drift_test.rb`
- Modify: `cybros/test/integration/setup_and_sessions_test.rb`

**Step 1: Write the failing checklist and tests**

Cover:

- `Agent` owns the configured runtime transport/auth/health/capability fields needed for live RPC and attachment transfer
- active runtime selection, hook dispatch, planning, finalization, and attachment import no longer require `AgentDeployment`
- `RecognizedDeployment` resolution can derive a stable identity from an `Agent`-owned runtime configuration object
- default bundled bootstrap provisions a fully runnable `Agent` without having to sync a legacy deployment row first

**Step 2: Run tests to expose the current mismatch**

Run: `bin/rails test test/models/agent_test.rb test/models/recognized_deployment_test.rb test/services/agent_rpc/lifecycle_caller_test.rb test/integration/agent_rpc_session_auth_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb test/integration/recognized_deployment_drift_test.rb test/integration/setup_and_sessions_test.rb`

Expected: FAIL because live runtime services still resolve endpoint/auth/capability state through `AgentDeployment` or `recognized_deployment.legacy_agent_deployment`.

**Step 3: Write minimal implementation**

Implement:

- add deployment-like transport/auth/health/capability columns directly to `agents`
- expose `Agent` runtime-reader methods using those native columns rather than `legacy_agent_program` / `AgentDeployment`
- cut RPC client, session authorization, lifecycle calling, attachment transfer, bootstrap hook dispatch, planning, and finalization over to the `Agent`-owned runtime configuration object
- update recognized-deployment resolution so runtime identity derives from the live `Agent` binding, not the legacy deployment association

**Step 4: Run verification**

Run: `bin/rails db:migrate`

Run: `RAILS_ENV=test bin/rails db:migrate`

Run: `bin/rails test test/models/agent_test.rb test/models/recognized_deployment_test.rb test/services/agent_rpc/lifecycle_caller_test.rb test/integration/agent_rpc_session_auth_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb test/integration/recognized_deployment_drift_test.rb test/integration/setup_and_sessions_test.rb`

Run: `rg -n "(legacy_agent_deployment|active_healthy_deployment_for_published_contract|AgentDeployment)" app/services/agents/rpc_client.rb app/services/agent_rpc/session_authorizer.rb app/services/agent_rpc/lifecycle_caller.rb app/services/conversations/attachment_transfer_service.rb app/services/conversations/bootstrap_hook_dispatcher.rb app/services/run_drafts/conversation_turn_planning_service.rb app/services/run_drafts/finalize_service.rb lib/cybros/programmable_agent/recognized_deployment_resolver.rb`

Expected: PASS for migrations and tests, and the grep should show no live runtime-resolution dependence on `legacy_agent_deployment` or `AgentDeployment` in the cut-over runtime paths.

**Step 5: Commit**

```bash
git add db/migrate/20260313170000_move_runtime_transport_configuration_to_agents.rb db/schema.rb app/models/agent.rb app/models/recognized_deployment.rb app/services/agents/bootstrap_bundled_default_service.rb app/services/agents/rpc_client.rb app/services/agent_rpc/session_authorizer.rb app/services/agent_rpc/lifecycle_caller.rb app/services/conversations/attachment_transfer_service.rb app/services/conversations/bootstrap_hook_dispatcher.rb app/services/run_drafts/conversation_turn_planning_service.rb app/services/run_drafts/finalize_service.rb lib/cybros/programmable_agent/recognized_deployment_resolver.rb test/models/agent_test.rb test/models/recognized_deployment_test.rb test/services/agent_rpc/lifecycle_caller_test.rb test/integration/agent_rpc_session_auth_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb test/integration/recognized_deployment_drift_test.rb test/integration/setup_and_sessions_test.rb
git commit -m "refactor: move runtime transport configuration to agents"
```

### Task 19B: Delete Legacy Runtime Schema, Models, Services, And Docs

**Files:**
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/automation.rb`
- Delete: `cybros/app/models/agent_program.rb`
- Delete: `cybros/app/models/agent_deployment.rb`
- Delete: `cybros/app/models/execution_target.rb`
- Delete: `cybros/app/models/execution_location.rb`
- Delete: `cybros/app/models/workspace.rb`
- Delete or Replace: `cybros/app/services/agent_programs/`
- Delete or Replace: `cybros/app/services/agent_deployments/`
- Modify: `cybros/app/services/conversations/attachment_transfer_service.rb`
- Modify: `cybros/app/services/agents/rpc_client.rb`
- Modify: `cybros/app/services/statistics/tool_call_fact_projector.rb`
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/config/routes.rb`
- Modify: `cybros/db/schema.rb`
- Create: `cybros/db/migrate/20260313190000_drop_legacy_runtime_schema.rb`
- Modify: `cybros/docs/product/README.md`
- Modify: `cybros/docs/product/vision.md`
- Modify: `cybros/docs/agent_core/public_api.md`
- Modify: `cybros/docs/agent_core/security.md`
- Modify: `cybros/docs/plans/2026-03-13-conversation-agent-runtime-simplification-design.md`

**Step 1: Write the failing checklist and audits**

Cover:

- no live runtime table, column, foreign key, or index remains for `AgentProgram`, `AgentDeployment`, `ExecutionTarget`, `ExecutionLocation`, or infrastructure `Workspace`
- `attachment_transfer_service` and `Agents::RPCClient` no longer fall back through `legacy_agent_deployment`
- no route/controller/write path still refers to legacy ids
- the temporary read adapters left in `Conversation` and `Automation` after Task 15 are deleted here because downstream runtime readers are now gone
- product and technical docs describe only `Conversation`, `Agent`, `RecognizedDeployment`, logical workspace, and attachment transfer

**Step 2: Run audits to expose the current mismatch**

Run: `rg -n "(legacy_agent_program_id|legacy_execution_target_id|agent_program_id|agent_deployment_id|default_execution_target_id|execution_target_id|proposed_execution_target_id|legacy_agent_deployment_id)" app db/schema.rb`

Run: `rg -n "(agent_programs?|agent_deployments?|execution_targets?|execution_locations?|default_execution_target|AgentProgram|AgentDeployment|ExecutionTarget|ExecutionLocation)" app config/routes.rb docs/product docs/agent_core`

Run: `bin/rails db:drop db:create db:migrate`

Run: `RAILS_ENV=test bin/rails db:drop db:create db:migrate`

Expected: FAIL with live schema/runtime/doc references still present, or with migrations that still depend on the old schema.

**Step 3: Write minimal implementation**

Implement:

- delete legacy runtime models after Tasks 15-19A have removed their live code and fixture dependencies
- add the schema-drop migration that removes obsolete legacy columns, foreign keys, and indexes
- remove or rename obsolete service namespaces
- remove remaining legacy fallbacks from attachment transfer and RPC client code
- update product and technical docs to the simplified runtime contract

**Step 4: Run verification**

Run: `bin/rails db:drop db:create db:migrate`

Run: `RAILS_ENV=test bin/rails db:drop db:create db:migrate`

Run: `bin/rails test test/integration/agent_runtime_simplification_contract_test.rb test/integration/recognized_deployment_drift_test.rb test/integration/agent_upgrade_conversation_binding_test.rb test/integration/dashboard_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/external_agent_attachment_transfer_test.rb`

Run: `rg -n "(legacy_agent_program_id|legacy_execution_target_id|agent_program_id|agent_deployment_id|default_execution_target_id|execution_target_id|proposed_execution_target_id|legacy_agent_deployment_id)" app db/schema.rb`

Run: `rg -n "(agent_programs?|agent_deployments?|execution_targets?|execution_locations?|default_execution_target|AgentProgram|AgentDeployment|ExecutionTarget|ExecutionLocation)" app config/routes.rb docs/product docs/agent_core`

Expected: PASS for the reset migrations and focused tests, and both grep audits return no live runtime references outside intentionally historical archived plans/docs.

**Step 5: Commit**

```bash
git add -A app/models app/services app/controllers config/routes.rb db docs/product docs/agent_core docs/plans/2026-03-13-conversation-agent-runtime-simplification-design.md
git commit -m "refactor: delete legacy runtime schema and docs"
```

### Task 20: Final Relationship Audit And Delivery Verification

**Files:**
- Modify: `cybros/test/integration/agent_upgrade_conversation_binding_test.rb`
- Modify: `cybros/test/integration/dashboard_test.rb`
- Modify: `cybros/test/integration/recognized_deployment_drift_test.rb`
- Modify: `cybros/test/e2e/dashboard.spec.ts`
- Modify: `cybros/test/e2e/helpers.ts`
- Modify: `cybros/docs/plans/2026-03-13-conversation-agent-runtime-simplification.md`

**Step 1: Write the failing delivery-guard tests**

Cover:

- updating an `Agent` changes future turn planning for conversations bound to that agent
- historical `RunDraft` / `ConversationRun` rows remain pinned to the recognized deployment captured at planning/finalization time
- an in-flight runtime identity change after an agent upgrade still fails safe as drift
- dashboard agent launchers create conversations with the correct `agent_id`
- no active product path can create a conversation without an `Agent` or bind a run to a mismatched `Agent` / `RecognizedDeployment`

**Step 2: Run the focused audit suites**

Run: `bin/rails test test/integration/agent_upgrade_conversation_binding_test.rb test/integration/dashboard_test.rb test/integration/recognized_deployment_drift_test.rb`

Run: `RAILS_ENV=development bin/ci_e2e test/e2e/dashboard.spec.ts`

Expected: either FAIL with a precise relationship/drift/dashboard gap to fix before delivery, or PASS with no further code changes required in this audit pass.

**Step 3: Write minimal follow-up fixes**

If Step 2 failed, implement only the relationship, drift, or dashboard-launch fixes uncovered by the delivery-guard tests, then rerun Step 2 until green. If Step 2 already passed, record that no follow-up code changes were needed and continue to Step 4.

**Step 4: Run the delivery gates**

Run: `bin/ci`

Run: `RAILS_ENV=development bin/ci_e2e`

Expected: PASS

**Step 5: Run the final stale-surface audit, record follow-up gaps, and commit**

Run: `rg -n "(agent_programs?|agent_deployments?|execution_targets?|execution_locations?|default_execution_target|AgentProgram|AgentDeployment|ExecutionTarget|ExecutionLocation)" app config/routes.rb docs/product`

Run: `rg -n "(system_settings_workspaces|resources :workspaces|class Workspace|belongs_to :workspace|has_many :workspaces|Workspace\\.)" app config/routes.rb docs/product`

Run: `rg -n "(legacy_agent_program_id|legacy_execution_target_id|agent_program_id|agent_deployment_id|default_execution_target_id|execution_target_id|proposed_execution_target_id|legacy_agent_deployment_id)" app db/schema.rb test/test_helper.rb test/e2e`

Update the plan document with a short verification note if any tests must be deferred due to environment or fixture limitations.

```bash
git add test/integration/agent_upgrade_conversation_binding_test.rb test/integration/dashboard_test.rb test/integration/recognized_deployment_drift_test.rb test/e2e/dashboard.spec.ts test/e2e/helpers.ts docs/plans/2026-03-13-conversation-agent-runtime-simplification.md
git commit -m "chore: verify conversation agent runtime cutover"
```
