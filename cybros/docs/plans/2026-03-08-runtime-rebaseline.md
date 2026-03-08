# Runtime Rebaseline Implementation Plan

> **Update 2026-03-09:** The deployment registration model, transport model, and run-draft semantics in this plan are superseded by `docs/plans/2026-03-09-agent-deployment-connection-design.md` and `docs/plans/2026-03-09-agent-deployment-connection.md`. Do not implement `AgentHost`, stdio-only transport, or pre-draft `ConversationRun` assumptions from this file as written.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebaseline Cybros around the correct long-term architecture: runtime kernel, programmable agent deployments, and execution targets.

**Architecture:** Replace metadata-driven product state with first-class domain models. Keep the proven DAG/runtime core where it still matches the target, but allow destructive rewrites of the product-facing model and Nexus integration semantics when they do not.

**Tech Stack:** Ruby on Rails, PostgreSQL, AgentCore/DAG, Hotwire, Go (Nexus), OpenAPI

## Testing Posture

Every behavior-changing task in this plan should name exact verification files and commands.

- pure domain or runtime tasks should land model or unit tests first
- runtime-bridging tasks should add integration coverage before code is considered done
- the first user-visible task that exposes a behavior should add or update a Playwright E2E flow for that behavior
- avoid wildcard-only acceptance or full-suite commands except for final verification or cross-project smoke checks

---

### Task 1: Freeze The Old Product Definition

**Files:**
- Modify: `docs/product/README.md`
- Modify: `docs/product/roadmap.md`
- Modify: `docs/product/agent_program_framework.md`
- Modify: `docs/product/conversation_behavior_spec.md`
- Modify: `docs/product/conversation_message_parity_audit.md`
- Create: `docs/archive/pre-runtime-rebaseline/product/*`
- Create: `docs/product/vision.md`
- Create: `docs/product/architecture.md`
- Create: `docs/product/domain_model.md`
- Create: `docs/product/state_taxonomy.md`
- Create: `docs/product/execution_model.md`
- Create: `docs/product/programmable_agents.md`
- Create: `docs/product/nexus_role.md`
- Create: `docs/product/migration_alignment.md`
- Create: `docs/plans/2026-03-08-phase-1-schema-cut-list.md`

**Step 1: Verify the current product docs are archived**

Run: `find docs/archive/pre-runtime-rebaseline/product -maxdepth 2 -type f | sort`
Expected: archived copies of the old `docs/product/*.md` files exist.

**Step 2: Write the new normative product docs**

Cover:

- runtime-kernel positioning
- programmable-agent contract
- execution target model
- state taxonomy
- Nexus role
- migration alignment

**Step 3: Replace the live product roadmap**

The live roadmap should reflect the new phase order and explicitly allow destructive refactors.

**Step 4: Commit**

```bash
git add docs/archive/pre-runtime-rebaseline/product docs/product docs/plans/2026-03-08-runtime-rebaseline-design.md docs/plans/2026-03-08-runtime-rebaseline.md docs/plans/2026-03-08-phase-1-schema-cut-list.md
git commit -m "docs: rebaseline product architecture"
```

### Task 2: Introduce The Execution Domain Model

This task is superseded in detail by the 2026-03-09 deployment-connection plan.

**Files:**
- Create: `db/migrate/*_create_agent_deployments.rb`
- Create: `app/models/agent_deployment.rb`
- Create: `db/migrate/*_create_execution_locations.rb`
- Create: `db/migrate/*_create_workspaces.rb`
- Create: `db/migrate/*_create_execution_targets.rb`
- Create: `db/migrate/*_create_automations.rb`
- Create: `db/migrate/*_create_automation_runs.rb`
- Create or modify: `db/migrate/*_rename_llm_providers_to_llm_provider_credentials.rb`
- Create or modify: `db/migrate/*_add_rate_limit_config_to_llm_provider_credentials.rb`
- Create: `db/migrate/*_create_runtime_settings.rb`
- Create: `app/models/execution_location.rb`
- Create: `app/models/workspace.rb`
- Create: `app/models/execution_target.rb`
- Create: `app/models/automation.rb`
- Create: `app/models/automation_run.rb`
- Modify: provider credential model(s)
- Create: `app/models/runtime_setting.rb`
- Modify: `db/schema.rb`

**Step 1: Write the failing model tests**

Create tests for:

- `AgentDeployment`
- `ExecutionLocation`
- `Workspace`
- `ExecutionTarget`
- `Automation`
- `AutomationRun`
- provider credential limit config
- execution quota config
- job concurrency settings shape
- required associations and validations

**Step 2: Run the targeted tests to confirm failure**

Run: `bin/rails test test/models/agent_deployment_test.rb test/models/execution_location_test.rb test/models/workspace_test.rb test/models/execution_target_test.rb test/models/automation_test.rb test/models/automation_run_test.rb test/models/llm_provider_credential_test.rb test/models/runtime_setting_test.rb`
Expected: missing model or table failures under the superseding deployment model.

**Step 3: Add the tables and models**

The schema should:

- make `workspace` location-scoped
- make `execution_target` the reusable product handle
- enforce execution-target location/workspace consistency
- make `agent_deployment` the runnable and connectable binding for the program
- land automation primitives on top of the same agent and execution-target model
- attach limiter settings to provider credentials
- attach execution quota settings to locations and target overrides
- add deployment-scoped runtime settings for operator-tuned job throughput

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/models/agent_deployment_test.rb test/models/execution_location_test.rb test/models/workspace_test.rb test/models/execution_target_test.rb test/models/automation_test.rb test/models/automation_run_test.rb test/models/llm_provider_credential_test.rb test/models/runtime_setting_test.rb`
Expected: PASS.

**Step 5: Commit**

```bash
git add db/migrate app/models db/schema.rb test/models
git commit -m "feat: add execution target domain models"
```

### Task 2.5: Bootstrap Runtime Defaults And Freeze ConversationRun Snapshot

**Files:**
- Create: `app/services/runtime/bootstrapper.rb`
- Modify: `db/seeds.rb`
- Modify: `app/models/conversation_run.rb`
- Modify: `app/controllers/conversations_controller.rb`
- Test: `test/services/runtime/bootstrapper_test.rb`
- Test: `test/models/conversation_run_test.rb`
- Test: `test/integration/conversation_runtime_bootstrap_test.rb`
- Test: `test/e2e/conversation_runtime_bootstrap_and_audit.spec.ts`

**Step 1: Write the failing tests**

Cover:

- fresh environments get a usable default `AgentProgram`, active `AgentDeployment`, `ExecutionLocation`, `Workspace`, `ExecutionTarget`, and `RuntimeSetting`
- migrated environments can backfill those defaults before conversation creation flips to first-class relations
- `ConversationRun` snapshots are versioned and immutable after queue time
- the create -> run -> audit business flow works through the real UI with bootstrap defaults in place

**Step 2: Run the targeted tests**

Run: `bin/rails test test/services/runtime/bootstrapper_test.rb test/models/conversation_run_test.rb test/integration/conversation_runtime_bootstrap_test.rb`
Expected: failures due to missing bootstrap service and missing snapshot contract.

Run: `bin/e2e test/e2e/conversation_runtime_bootstrap_and_audit.spec.ts`
Expected: FAIL once the dev server is running because the bootstrap and audit flow is not yet wired.

**Step 3: Implement the bootstrap and snapshot contract**

Land:

- one bootstrap path for fresh and migrated environments
- a versioned `ConversationRun.snapshot`
- draft finalization before queue-time snapshot freezing
- a controller path that can resolve defaults without relying on metadata-owned product state

Keep transitional metadata reads isolated so later tasks can delete them cleanly.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/services/runtime/bootstrapper_test.rb test/models/conversation_run_test.rb test/integration/conversation_runtime_bootstrap_test.rb`
Expected: PASS.

Run: `bin/e2e test/e2e/conversation_runtime_bootstrap_and_audit.spec.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add app/services/runtime app/models/conversation_run.rb app/controllers/conversations_controller.rb db/seeds.rb test/services/runtime test/models/conversation_run_test.rb test/integration/conversation_runtime_bootstrap_test.rb test/e2e/conversation_runtime_bootstrap_and_audit.spec.ts
git commit -m "feat: bootstrap runtime defaults and freeze run snapshots"
```

### Task 3: Rework Conversation And Run Ownership

**Files:**
- Modify: `db/migrate/*_create_conversations.rb` or replacement migration set
- Modify: `db/migrate/*_create_conversation_runs.rb` or replacement migration set
- Modify: `app/models/conversation.rb`
- Modify: `app/models/conversation_run.rb`
- Modify: `app/controllers/conversations_controller.rb`
- Modify: `app/controllers/conversation_messages_controller.rb`
- Test: `test/models/conversation_chat_facade_test.rb`
- Test: `test/models/conversation_run_test.rb`
- Test: `test/integration/conversations_test.rb`

**Step 1: Write failing tests for first-class conversation relations**

Add coverage for:

- conversation belongs to `agent_program`
- conversation resolves through an `agent_deployment`
- conversation belongs to default `execution_target`
- conversation run snapshots the effective target and agent inputs
- controller and runtime paths no longer require `metadata["agent"]` or `metadata["llm"]` as canonical product state

**Step 2: Run the targeted tests**

Run: `bin/rails test test/models/conversation_chat_facade_test.rb test/integration/conversations_test.rb`
Expected: failures around missing relations or old metadata assumptions.

**Step 3: Replace metadata-driven creation paths**

Remove the hard dependency on `metadata["agent"]["agent_profile"]` for product-level ownership.

**Step 4: Re-run tests**

Run: `bin/rails test test/models/conversation_chat_facade_test.rb test/integration/conversations_test.rb`
Expected: PASS.

Run: `rg -n 'metadata\\["agent"\\]|metadata\\["llm"\\]' app/controllers/conversations_controller.rb lib/cybros/agent_runtime_resolver.rb`
Expected: no canonical product-ownership reads remain in those hot paths.

**Step 5: Commit**

```bash
git add app/models/conversation.rb app/models/conversation_run.rb app/controllers/conversations_controller.rb app/controllers/conversation_messages_controller.rb db/migrate db/schema.rb test/models test/integration
git commit -m "feat: bind conversations to agent programs and execution targets"
```

### Task 4: Add Conversation Public Settings, Agent Config, And Shared KV

**Files:**
- Create: `db/migrate/*_create_conversation_kv_entries.rb`
- Create: `app/models/conversation_kv_entry.rb`
- Modify: `app/models/conversation.rb`
- Create: `app/services/conversations/settings_service.rb`
- Create: `app/services/conversations/agent_config_service.rb`
- Create: `app/services/conversations/kv_service.rb`
- Test: `test/models/conversation_kv_entry_test.rb`
- Test: `test/services/conversations/agent_config_service_test.rb`
- Test: `test/models/conversation_chat_facade_test.rb`

**Step 1: Write failing tests for settings and KV behavior**

Cover:

- shared visibility across agent switches
- explicit agent-config reads and writes through a public API boundary
- reserved separation between settings, agent config, and KV
- reserved `system.*` behavior
- JSON value storage
- audit-safe mutation paths

**Step 2: Run the targeted tests**

Run: `bin/rails test test/models/conversation_kv_entry_test.rb test/services/conversations/agent_config_service_test.rb`
Expected: missing model or API failures.

**Step 3: Implement the model and public API**

Keep the public boundary explicit. Do not route agent control through ad hoc metadata writes.

If agent-schema discovery is not wired yet, keep one explicit validation seam so Phase 2 can tighten agent-config validation without changing the public API shape.

**Step 4: Re-run tests**

Run: `bin/rails test test/models/conversation_kv_entry_test.rb test/services/conversations/agent_config_service_test.rb test/models/conversation_chat_facade_test.rb`
Expected: PASS.

**Step 5: Commit**

```bash
git add app/models app/services db/migrate db/schema.rb test/models test/services/conversations/agent_config_service_test.rb
git commit -m "feat: add conversation settings agent config and shared kv"
```

### Task 5: Historical AgentProgram Lifecycle Task

This task is retained only as historical context.

Under the 2026-03-09 superseding design:

- `AgentProgram` owns source identity, manifest, and agent-defined config contract only
- deployment connectivity, inspection, activation, and health belong to `AgentDeployment`
- do not recreate `AgentHost` as a v1 product model from this task

If this area is revived later, rewrite it around deployment registration and inspection flows rather than setup/install lifecycle on `AgentProgram`.

**Files:**
- Modify: `app/models/agent_program.rb`
- Modify: `app/services/agent_programs/loader.rb`
- Modify: `app/services/agent_programs/creator.rb`
- Create: `app/services/agent_programs/setup_runner.rb`
- Create: `app/services/agent_programs/healthcheck_runner.rb`
- Test: `test/services/agent_programs/loader_test.rb`
- Test: `test/services/agent_programs/setup_runner_test.rb`
- Test: `test/services/agent_programs/healthcheck_runner_test.rb`
- Test: `test/integration/agent_programs_test.rb`
- Test: `test/integration/system_settings_agent_programs_test.rb`
- Test: `test/e2e/agent_programs_settings.spec.ts`

**Step 1: Historical tests only**

This historical task used to cover:

- manifest snapshot
- setup state
- health state
- Ruby-first setup path
- deployment failure surfaced as a specific retryable runtime error
- operator-visible lifecycle state through the settings UI

**Step 2: Historical test commands**

Run: `bin/rails test test/services/agent_programs/loader_test.rb test/services/agent_programs/setup_runner_test.rb test/services/agent_programs/healthcheck_runner_test.rb test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb`
Expected: obsolete guidance under the superseding deployment model.

Run: `bin/e2e test/e2e/agent_programs_settings.spec.ts`
Expected: obsolete guidance under the superseding deployment model.

**Step 3: Do not implement this task as written**

**Step 4: Historical verification only**

Run: `bin/rails test test/services/agent_programs/loader_test.rb test/services/agent_programs/setup_runner_test.rb test/services/agent_programs/healthcheck_runner_test.rb test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb`
Expected: obsolete guidance under the superseding deployment model.

Run: `bin/e2e test/e2e/agent_programs_settings.spec.ts`
Expected: obsolete guidance under the superseding deployment model.

**Step 5: Historical commit**

```bash
git add app/models app/services test/services/agent_programs test/integration test/e2e/agent_programs_settings.spec.ts
git commit -m "historical: old programmable agent lifecycle task"
```

### Task 6: Rebaseline Runtime Resolution On Execution Targets

**Files:**
- Modify: `lib/cybros/agent_runtime_resolver.rb`
- Modify: `lib/agent_core/dag/execution_context_builder.rb`
- Modify: `lib/agent_core/prompt_builder/system_prompt_sections_builder.rb`
- Test: `test/lib/cybros/agent_runtime_resolver_test.rb`
- Test: `test/lib/agent_core/dag/runtime_execution_context_attributes_test.rb`

**Step 1: Write failing tests for execution-target-backed context**

Cover:

- `cwd/workspace_dir` coming from the selected execution target
- agent and target snapshots appearing in execution context

**Step 2: Run the targeted tests**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_test.rb test/lib/agent_core/dag/runtime_execution_context_attributes_test.rb`
Expected: failures due to current `Rails.root/Dir.pwd` defaults.

**Step 3: Replace the old defaults**

Bind runtime resolution to first-class conversation and run records.

**Step 4: Re-run tests**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_test.rb test/lib/agent_core/dag/runtime_execution_context_attributes_test.rb`
Expected: PASS.

**Step 5: Commit**

```bash
git add lib/cybros/agent_runtime_resolver.rb lib/agent_core/dag/execution_context_builder.rb lib/agent_core/prompt_builder/system_prompt_sections_builder.rb test/lib
git commit -m "feat: resolve runtime context from execution targets"
```

### Task 7: Re-align Conduits And Nexus Semantics

**Files:**
- Modify: `nexus/docs/protocol/conduits_api_openapi.yaml`
- Modify: `mothership/app/models/conduits/facility.rb`
- Modify: `mothership/app/models/conduits/directive.rb`
- Modify: `docs/product/nexus_role.md`
- Test: `mothership/test/models/conduits/facility_test.rb`
- Test: `mothership/test/models/conduits/directive_test.rb`
- Test: `mothership/test/services/conduits/command_target_resolver_test.rb`
- Test: `mothership/test/integration/conduits_e2e_test.rb`
- Test: `mothership/test/scripts/openapi_contract_smoke.rb`
- Test: `nexus/protocol/types_test.go`
- Test: `nexus/client/client_test.go`

**Step 1: Write the protocol delta doc**

Document the meaning shift from legacy execution subsystem concepts to the new execution-target model.

**Step 2: Update the protocol spec first**

The OpenAPI file remains the source of truth.

**Step 3: Port the model/controller changes**

Keep Nexus execution-only. Do not add programmable-agent deployment control-plane duties here.

**Step 4: Run both sides**

Run:

- `cd mothership && bin/rails test test/models/conduits/facility_test.rb test/models/conduits/directive_test.rb test/services/conduits/command_target_resolver_test.rb test/integration/conduits_e2e_test.rb`
- `cd mothership && ruby test/scripts/openapi_contract_smoke.rb`
- `cd nexus && go test ./protocol ./client`

Expected: PASS on both projects.

**Step 5: Commit**

```bash
git add nexus/docs/protocol mothership docs/product/nexus_role.md
git commit -m "feat: realign conduits with execution target semantics"
```

### Task 8: Rebuild The Product Surface

**Files:**
- Modify: `app/controllers/conversations_controller.rb`
- Modify: `app/views/conversations/**/*`
- Modify: `app/controllers/system/settings/agent_programs_controller.rb`
- Create: `app/controllers/system/settings/execution_locations_controller.rb`
- Create: `app/controllers/system/settings/workspaces_controller.rb`
- Create: `app/controllers/system/settings/execution_targets_controller.rb`
- Create: corresponding views under `app/views/system/settings/execution_locations/`, `app/views/system/settings/workspaces/`, and `app/views/system/settings/execution_targets/`
- Test: `test/integration/conversations_test.rb`
- Test: `test/integration/agent_programs_test.rb`
- Test: `test/integration/system_settings_agent_programs_test.rb`
- Test: `test/e2e/conversation_agent_target_selection.spec.ts`

**Step 1: Write failing integration tests**

Cover:

- conversation creation with explicit agent and target
- visible run snapshot data
- mutation of conversation settings through the public surface
- real browser flow for choosing agent and target, running work, and opening the run-audit surface

**Step 2: Run the targeted tests**

Run: `bin/rails test test/integration/conversations_test.rb test/integration/agent_programs_test.rb`
Expected: failures due to old UI assumptions.

Run: `bin/e2e test/e2e/conversation_agent_target_selection.spec.ts`
Expected: FAIL once the dev server is running because the new surface is not yet wired.

**Step 3: Implement the new surfaces**

Prefer removing old assumptions over adapting them.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/integration/conversations_test.rb test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb`
Expected: PASS.

Run: `bin/e2e test/e2e/conversation_agent_target_selection.spec.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add app/controllers app/views test/integration test/e2e/conversation_agent_target_selection.spec.ts
git commit -m "feat: expose agent and execution target selection in the ui"
```
