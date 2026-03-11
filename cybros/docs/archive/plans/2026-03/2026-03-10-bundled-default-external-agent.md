# Bundled Default External Agent Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the builtin conversation-agent runtime with a bundled default external programmable agent, then add a copy-as-custom workflow that preserves capability parity, restart safety, and per-deployment endpoint isolation.

**Architecture:** Add explicit bundled/custom source ownership to `AgentProgram`, ship a real bundled default agent plus an out-of-process companion host, generate deployment-specific runtime config with allocated endpoints and bearer credentials, bootstrap a default program/deployment during setup, delete the builtin conversation fallback, and add a product-managed fork flow that copies source into a user-owned git repository and provisions a normal deployment.

**Tech Stack:** Ruby on Rails, ActiveRecord migrations, Hotwire/ERB, JSON-RPC `agent_rpc`, git CLI, Procfile.dev, Docker Compose

## Milestone 1 Acceptance Bar

Milestone 1 does not try to prove that Cybros can already fully replicate every target agent category.

It must prove these narrower claims:

- Cybros can run its own default agent as a real external programmable agent
- the bundled default agent is a complete source program under `agents/default`, not a profile asset or placeholder gem packaging scaffold
- the bundled default agent is good enough to serve as the product's default interactive assistant
- the bundled default agent can also clear a light coding-agent bar while keeping loop ownership, policy, approvals, and governed execution inside Cybros

After that first acceptance, the project should use these reference classes as challenge suites to refine the substrate:

- general / universal agents
- research agents
- chat / roleplay / companion agents
- trading agents

Challenge-suite failures should be used to decide whether the missing capability belongs in:

- Cybros substrate
- the programmable-agent contract
- the bundled default agent package
- or a category-specific external agent

## Autonomy Gate

There is no remaining design blocker for milestone 1 if implementation treats these as fixed decisions rather than open questions:

- bundled runtime identity is singular: bundled key `default`, source root `agents/default`
- `default-assistant` is legacy trace only
- execution-capable conversations must not proceed without `agent_program_id`
- official local development and official compose flows must auto-launch the bundled default deployment and forked custom deployments
- `generated-config-ready` is only acceptable for unsupported external deployment topologies, not for the core milestone-1 acceptance path
- milestone-1 completion requires one bundled-default end-to-end loop and one forked-agent end-to-end loop through Cybros

---

### Task 1: Model Source Ownership And Workspace Root

**Files:**
- Create: `db/migrate/20260310100000_add_agent_source_fields_and_workspace_root.rb`
- Modify: `app/models/agent_program.rb`
- Modify: `app/models/conversation.rb`
- Modify: `app/models/runtime_setting.rb`
- Modify: `app/controllers/system/settings/runtime_settings_controller.rb`
- Modify: `app/views/system/settings/runtime_settings/_form.html.erb`
- Modify: `app/views/system/settings/runtime_settings/show.html.erb`
- Create: `test/models/conversation_program_selection_test.rb`
- Test: `test/models/agent_program_test.rb`
- Test: `test/models/runtime_setting_test.rb`
- Test: `test/integration/system_settings_runtime_settings_test.rb`
- Test: `test/system/system_settings_runtime_settings_test.rb`

**Step 1: Write the failing model and settings tests**

Add assertions like:

```ruby
test "bundled programs require bundled_agent_key" do
  program = AgentProgram.new(
    name: "Default assistant",
    source_kind: "bundled",
    bundled_agent_key: "",
    local_path: "agents/default"
  )

  assert_not program.valid?
  assert_includes program.errors[:bundled_agent_key], "can't be blank"
end

test "runtime setting accepts agent workspace root" do
  setting = RuntimeSetting.new(
    scope_key: "instance",
    default_worker_concurrency: 12,
    queue_overrides: {},
    alert_thresholds: {},
    agent_workspace_root: "/srv/cybros-agents"
  )

  assert setting.valid?
end

test "execution-capable conversations require an agent program" do
  conversation = Conversation.new(title: "Conversation", user: users(:owner))

  assert_not conversation.valid?
  assert_includes conversation.errors[:agent_program], "must exist"
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/agent_program_test.rb test/models/runtime_setting_test.rb test/models/conversation_program_selection_test.rb test/integration/system_settings_runtime_settings_test.rb test/system/system_settings_runtime_settings_test.rb`

Expected: failures about unknown attributes and missing validations for source ownership and `agent_workspace_root`.

**Step 3: Write the minimal schema and model changes**

Implement:

```ruby
add_column :agent_programs, :source_kind, :string, null: false, default: "custom"
add_column :agent_programs, :bundled_agent_key, :string
add_reference :agent_programs, :forked_from_agent_program, type: :string, foreign_key: { to_table: :agent_programs }
add_column :runtime_settings, :agent_workspace_root, :string
```

and model rules like:

```ruby
SOURCE_KINDS = %w[bundled custom].freeze

validates :source_kind, inclusion: { in: SOURCE_KINDS }
validates :bundled_agent_key, presence: true, if: -> { source_kind == "bundled" }
validates :agent_workspace_root, presence: true
```

Keep the first pass narrow, but include the owner boundary changes required by the design:

- add explicit source-kind / fork metadata
- add operator-configured workspace root
- decide and implement how `AgentProgram` resolves bundled paths versus user-owned mounted paths
- add the model/schema enforcement that execution-capable conversations cannot proceed without an `agent_program_id`

**Step 4: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/agent_program_test.rb test/models/runtime_setting_test.rb test/models/conversation_program_selection_test.rb test/integration/system_settings_runtime_settings_test.rb test/system/system_settings_runtime_settings_test.rb`

Expected: PASS.

**Step 5: Commit**

```bash
git add db/migrate/20260310100000_add_agent_source_fields_and_workspace_root.rb app/models/agent_program.rb app/models/conversation.rb app/models/runtime_setting.rb app/controllers/system/settings/runtime_settings_controller.rb app/views/system/settings/runtime_settings/_form.html.erb app/views/system/settings/runtime_settings/show.html.erb test/models/agent_program_test.rb test/models/runtime_setting_test.rb test/models/conversation_program_selection_test.rb test/integration/system_settings_runtime_settings_test.rb test/system/system_settings_runtime_settings_test.rb
git commit -m "feat: model bundled agent source ownership"
```

### Task 2: Ship The Bundled Default Agent Package And External Host

**Files:**
- Create: `agents/default/agent.yml`
- Create: `agents/default/bin/server`
- Create: `agents/default/bin/test`
- Create: `agents/default/lib/cybros/agents/default.rb`
- Create: `agents/default/lib/cybros/agents/default/application.rb`
- Create: `agents/default/lib/cybros/agents/default/identity.rb`
- Create: `agents/default/lib/cybros/agents/default/manifest.rb`
- Create: `agents/default/lib/cybros/agents/default/rpc_server.rb`
- Create: `agents/default/lib/cybros/agents/default/rpc_dispatcher.rb`
- Create: `agents/default/lib/cybros/agents/default/hooks/prepare.rb`
- Create: `agents/default/lib/cybros/agents/default/hooks/compose.rb`
- Create: `agents/default/lib/cybros/agents/default/hooks/handle_error.rb`
- Create: `agents/default/prompts/AGENT.md`
- Create: `agents/default/prompts/SOUL.md`
- Create: `agents/default/prompts/USER.md`
- Create: `agents/default/prompts/system.md.liquid`
- Create: `agents/default/test/unit/manifest_test.rb`
- Create: `agents/default/test/integration/rpc_contract_test.rb`
- Modify: `agents/default/README.md`
- Modify: `agents/default/Gemfile`
- Modify: `agents/default/Rakefile`
- Create: `bin/default_agent_host`
- Create: `lib/cybros/bundled_agent_host/application.rb`
- Create: `lib/cybros/bundled_agent_host/router.rb`
- Create: `app/services/agent_programs/bundled_sources.rb`
- Modify: `app/services/agent_programs/creator.rb`
- Modify: `app/services/agent_programs/loader.rb`
- Delete: `agents/default/default.gemspec`
- Delete: `agents/default/lib/default.rb`
- Delete: `agents/default/lib/default/version.rb`
- Delete: `agents/default/test/test_default.rb`
- Delete: `agents/profiles/default-assistant/agent.yml`
- Delete: `agents/profiles/default-assistant/AGENT.md`
- Delete: `agents/profiles/default-assistant/SOUL.md`
- Delete: `agents/profiles/default-assistant/USER.md`
- Delete: `agents/profiles/default-assistant/prompts/system.md.liquid`
- Test: `test/integration/agent_programs_test.rb`
- Test: `test/integration/agent_deployments_inspection_test.rb`
- Test: `test/lib/cybros/bundled_agent_host_test.rb`

**Step 1: Write the failing bundled-source and host tests**

Add tests that prove:

```ruby
test "bundled source registry exposes the default bundled agent" do
  assert_includes AgentPrograms::BundledSources.available_keys, "default"
end

test "default bundled agent host responds to required methods" do
  host = Cybros::BundledAgentHost::Application.new(source_root: Rails.root.join("agents/default"))

  assert_includes host.supported_methods, "initialize"
  assert_includes host.supported_methods, "turn.prepare"
  assert_includes host.supported_methods, "turn.compose"
  assert_includes host.supported_methods, "turn.handle_error"
end

test "bundled default agent package exposes manifest and rpc contract" do
  manifest = Cybros::Agents::Default::Manifest.load!(source_root: Rails.root.join("agents/default"))

  assert_equal "default", manifest.fetch("agent_program_key")
  assert_includes manifest.fetch("supported_methods"), "turn.prepare"
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/agent_programs_test.rb test/integration/agent_deployments_inspection_test.rb test/lib/cybros/bundled_agent_host_test.rb`

Expected: missing files/constants and failing expectations around bundled-source discovery and required RPC methods.

**Step 3: Implement the external host and source registry**

Land the first milestone as:

- `agents/default` becomes a real agent program rather than a placeholder gem scaffold
- `agents/default/agent.yml` describes the official bundled agent source
- `agents/default` keeps gem-style app structure for discipline and testability, but removes RubyGems packaging semantics
- the legacy prompt assets move from `agents/profiles/default-assistant` into `agents/default/prompts`
- the bundled source must not include nested `.git`
- `bin/default_agent_host` boots a standalone Ruby process
- `lib/cybros/bundled_agent_host/**` serves the required `agent_rpc` methods
- `AgentPrograms::BundledSources` replaces bundled-profile discovery
- `AgentPrograms::Creator` can create programs from bundled sources, not only copied no-op profiles
- the bundled source carries an immutable official `agent_program_key` of `default`
- the bundled agent package includes its own unit and RPC contract tests so the copied source remains testable as a standalone program

Use the current programmable-agent fixture behavior as the contract floor, not as a hidden runtime path.

**Step 4: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/agent_programs_test.rb test/integration/agent_deployments_inspection_test.rb test/lib/cybros/bundled_agent_host_test.rb`

Run: `cd agents/default && bundle exec ruby -Itest test/unit/manifest_test.rb test/integration/rpc_contract_test.rb`

Expected: PASS.

**Step 5: Commit**

```bash
git add agents/default/agent.yml agents/default/README.md agents/default/Gemfile agents/default/Rakefile agents/default/bin/server agents/default/bin/test agents/default/lib/cybros/agents/default.rb agents/default/lib/cybros/agents/default/application.rb agents/default/lib/cybros/agents/default/identity.rb agents/default/lib/cybros/agents/default/manifest.rb agents/default/lib/cybros/agents/default/rpc_server.rb agents/default/lib/cybros/agents/default/rpc_dispatcher.rb agents/default/lib/cybros/agents/default/hooks/prepare.rb agents/default/lib/cybros/agents/default/hooks/compose.rb agents/default/lib/cybros/agents/default/hooks/handle_error.rb agents/default/prompts/AGENT.md agents/default/prompts/SOUL.md agents/default/prompts/USER.md agents/default/prompts/system.md.liquid agents/default/test/unit/manifest_test.rb agents/default/test/integration/rpc_contract_test.rb bin/default_agent_host lib/cybros/bundled_agent_host/application.rb lib/cybros/bundled_agent_host/router.rb app/services/agent_programs/bundled_sources.rb app/services/agent_programs/creator.rb app/services/agent_programs/loader.rb test/integration/agent_programs_test.rb test/integration/agent_deployments_inspection_test.rb test/lib/cybros/bundled_agent_host_test.rb
git commit -m "feat: add bundled default external agent host"
```

### Task 3: Allocate Endpoints And Generate Deployment Runtime Config

**Files:**
- Create: `app/services/agent_deployments/endpoint_allocator.rb`
- Create: `app/services/agent_deployments/runtime_config_writer.rb`
- Modify: `app/services/agent_deployments/registration_service.rb`
- Modify: `app/services/agent_deployments/inspection_service.rb`
- Modify: `app/services/agent_deployments/activation_service.rb`
- Modify: `app/models/agent_deployment.rb`
- Create: `test/services/agent_rpc/lifecycle_caller_test.rb`
- Test: `test/models/agent_deployment_test.rb`
- Test: `test/integration/agent_deployments_registration_test.rb`
- Test: `test/integration/agent_deployments_activation_gate_test.rb`

**Step 1: Write the failing endpoint-allocation and restart-safety tests**

Add assertions like:

```ruby
test "registration allocates a unique port and writes runtime config" do
  program = agent_programs(:bundled_default)

  deployment = AgentDeployments::RegistrationService.new(
    agent_program: program,
    transport_kind: "http_jsonrpc",
    endpoint_url: "",
    deployment_bearer_secret_ref: "secret://deployment-one",
    deployment_fingerprint: "deployment:test-one"
  ).register!

  assert deployment.transport_config["port"].present?
  assert File.exist?(deployment.transport_config.fetch("runtime_config_path"))
end

test "registration persists endpoint allocation without trusting a fixed port" do
  deployment = agent_deployments(:inactive_bundled_default_candidate)

  assert_nil deployment.transport_config["port"]
  refute_equal "http://127.0.0.1:8001", deployment.endpoint_url
end

test "activation does not deactivate the old deployment before the new one is healthy" do
  old_deployment = agent_deployments(:active_bundled_default)
  new_deployment = agent_deployments(:inactive_bundled_default_candidate)

  new_deployment.update!(health_status: "unhealthy")

  assert_raises(AgentDeployments::ActivationError) do
    AgentDeployments::ActivationService.new(deployment: new_deployment).activate!
  end

  assert_equal "active", old_deployment.reload.status
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/agent_deployment_test.rb test/integration/agent_deployments_registration_test.rb test/integration/agent_deployments_activation_gate_test.rb`

Expected: no endpoint allocator, no generated runtime config path, and no explicit restart-safety guarantees.

**Step 3: Implement deployment-owned endpoint allocation**

Implement services that:

- allocate a free port per deployment
- persist the assigned endpoint in `AgentDeployment.transport_config`
- generate a deployment-specific runtime config file outside the git-managed source tree
- include deployment fingerprint and bearer-secret binding in that generated config
- persist endpoint allocation with a collision-safe ownership rule instead of a best-effort port probe

Keep the owner boundary clear:

- source tree owns agent code and static source config
- `transport_config` and generated runtime config own live endpoint binding
- launch ownership belongs to the companion deployment layer, not the source tree

**Step 4: Harden cutover rules**

Make sure activation semantics remain:

- inspect first
- require matching identity and healthy status
- only deactivate the old deployment after the new one is ready
- never let an in-flight run silently reconnect to a replacement process on the same port
- mark deployment-bound sessions stale when the underlying deployment dies or is replaced

Add one focused service-level test for the stale-session boundary:

- `test/services/agent_rpc/lifecycle_caller_test.rb` should prove that a deployment-bound session or replay attempt is rejected once the deployment is no longer the active healthy binding

**Step 5: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/agent_deployment_test.rb test/integration/agent_deployments_registration_test.rb test/integration/agent_deployments_activation_gate_test.rb test/services/agent_rpc/lifecycle_caller_test.rb`

Expected: PASS.

**Step 6: Commit**

```bash
git add app/services/agent_deployments/endpoint_allocator.rb app/services/agent_deployments/runtime_config_writer.rb app/services/agent_deployments/registration_service.rb app/services/agent_deployments/inspection_service.rb app/services/agent_deployments/activation_service.rb app/models/agent_deployment.rb test/models/agent_deployment_test.rb test/integration/agent_deployments_registration_test.rb test/integration/agent_deployments_activation_gate_test.rb test/services/agent_rpc/lifecycle_caller_test.rb
git commit -m "feat: add deployment endpoint allocation"
```

### Task 4: Bootstrap The Default Program And Deployment

**Files:**
- Create: `app/services/agent_programs/bootstrap_bundled_default_service.rb`
- Modify: `app/controllers/setups_controller.rb`
- Modify: `Procfile.dev`
- Modify: `compose.yaml.sample`
- Modify: `.devcontainer/compose.yaml`
- Modify: `test/e2e/helpers.ts`
- Create: `test/integration/bundled_default_agent_execution_test.rb`
- Test: `test/integration/setup_and_sessions_test.rb`
- Test: `test/integration/agent_deployments_registration_test.rb`
- Test: `test/e2e/bundled_default_agent_flow.spec.ts`
- Test: `test/e2e/settings.spec.ts`

**Step 1: Write the failing bootstrap tests**

Add assertions like:

```ruby
test "setup bootstraps the bundled default program and active deployment" do
  post setup_path, params: { identity: { email: "owner@example.com", password: "Passw0rd", password_confirmation: "Passw0rd" } }

  program = AgentProgram.find_by!(bundled_agent_key: "default")
  deployment = program.active_healthy_deployment

  assert_equal "bundled", program.source_kind
  assert_equal "healthy", deployment.health_status
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/setup_and_sessions_test.rb test/integration/agent_deployments_registration_test.rb`

Expected: setup does not create a bundled program/deployment yet.

**Step 3: Implement bootstrap and dev startup wiring**

Implement an idempotent service that:

- ensures the bundled default `AgentProgram` exists
- registers a companion `AgentDeployment` with deployment-owned endpoint allocation
- inspects and activates it when healthy
- records whether the default deployment is merely registered or actually launched by the current environment wiring

Then wire it into:

- `SetupsController#create`
- `Procfile.dev` so the host starts in local development
- `compose.yaml.sample` and `.devcontainer/compose.yaml` so the host is present in container flows

Be explicit in the code and tests about the promise level:

- local development and official compose paths should produce a launched default deployment
- the bundled default deployment must be runnable end-to-end in official local development and official compose flows
- unsupported external deployment topologies may still surface as generated-config-ready, but that fallback must not apply to the bundled default acceptance path

Add one direct integration proof and one browser proof for the default path:

- `test/integration/bundled_default_agent_execution_test.rb` should prove setup-created bundled default agent selection can open a `RunDraft`, finalize a `ConversationRun`, and complete one agent loop through the bundled host
- `test/e2e/bundled_default_agent_flow.spec.ts` should prove a fresh setup session can create a conversation, inherit the bundled default agent, send one message, and receive one bundled-agent response without manual deployment registration

**Step 4: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/setup_and_sessions_test.rb test/integration/agent_deployments_registration_test.rb test/integration/bundled_default_agent_execution_test.rb`

Run: `bunx playwright test test/e2e/bundled_default_agent_flow.spec.ts test/e2e/settings.spec.ts`

Expected: PASS.

**Step 5: Commit**

```bash
git add app/services/agent_programs/bootstrap_bundled_default_service.rb app/controllers/setups_controller.rb Procfile.dev compose.yaml.sample .devcontainer/compose.yaml test/e2e/helpers.ts test/integration/setup_and_sessions_test.rb test/integration/agent_deployments_registration_test.rb test/integration/bundled_default_agent_execution_test.rb test/e2e/bundled_default_agent_flow.spec.ts test/e2e/settings.spec.ts
git commit -m "feat: bootstrap bundled default agent"
```

### Task 5: Cut The Builtin Conversation Path

**Files:**
- Create: `db/migrate/20260310110000_backfill_legacy_builtin_conversations.rb`
- Modify: `app/models/conversation.rb`
- Modify: `app/controllers/conversations_controller.rb`
- Modify: `app/services/conversations/runtime_settings_updater.rb`
- Modify: `app/views/conversations/show.html.erb`
- Modify: `test/e2e/helpers.ts`
- Test: `test/integration/conversation_agent_program_selection_test.rb`
- Test: `test/models/conversation_chat_facade_test.rb`
- Test: `test/integration/setup_and_sessions_test.rb`

**Step 1: Write the failing conversation-path tests**

Cover both creation and UI:

```ruby
test "new conversations default to the bundled default agent" do
  post conversations_path, params: { conversation: { title: "Test" } }

  conversation = Conversation.order(:created_at).last
  program = AgentProgram.find_by!(bundled_agent_key: "default")

  assert_equal program.id, conversation.agent_program_id
end

test "conversation settings no longer show Built-in" do
  get conversation_path(conversations(:one))
  assert_select "option", text: "Built-in", count: 0
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/conversation_agent_program_selection_test.rb test/models/conversation_chat_facade_test.rb test/integration/setup_and_sessions_test.rb`

Expected: failures because conversations can still be created without an `agent_program_id`, the UI still renders `Built-in`, and the model still materializes builtin runs directly.

**Step 3: Remove the builtin fallback and backfill historical rows**

Implement the cut in one pass:

- default new conversations to the bundled default program
- remove the `Built-in` option from the conversation UI
- delete `builtin_agent_program`, `builtin_agent_deployment`, and direct `ConversationRun.create!` fallback code
- backfill legacy builtin conversations to the system-created bundled default program
- backfill or normalize any legacy profile-based default-agent rows onto the new bundled identity

Do not preserve a runtime compatibility branch.

**Step 4: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/conversation_agent_program_selection_test.rb test/models/conversation_chat_facade_test.rb test/integration/setup_and_sessions_test.rb`

Expected: PASS.

**Step 5: Commit**

```bash
git add db/migrate/20260310110000_backfill_legacy_builtin_conversations.rb app/models/conversation.rb app/controllers/conversations_controller.rb app/services/conversations/runtime_settings_updater.rb app/views/conversations/show.html.erb test/e2e/helpers.ts test/integration/conversation_agent_program_selection_test.rb test/models/conversation_chat_facade_test.rb test/integration/setup_and_sessions_test.rb
git commit -m "feat: remove builtin conversation agent path"
```

### Task 6: Add Copy-As-Custom And Git Bootstrap

**Files:**
- Create: `app/services/agent_programs/git_bootstrap.rb`
- Create: `app/services/agent_programs/fork_service.rb`
- Modify: `config/routes.rb`
- Modify: `app/controllers/system/settings/agent_programs_controller.rb`
- Modify: `app/views/system/settings/agent_programs/index.html.erb`
- Modify: `app/views/system/settings/agent_programs/show.html.erb`
- Create: `test/integration/forked_agent_execution_test.rb`
- Test: `test/integration/system_settings_agent_programs_test.rb`
- Test: `test/system/system_settings_agent_programs_test.rb`
- Test: `test/e2e/bundled_agent_fork_flow.spec.ts`

**Step 1: Write the failing fork-flow tests**

Add coverage like:

```ruby
test "copy as custom agent creates a forked program and git repo" do
  bundled = AgentProgram.find_by!(bundled_agent_key: "default")

  post fork_system_settings_agent_program_path(bundled), params: { name: "My assistant" }

  forked = AgentProgram.find_by!(name: "My assistant")
  assert_equal "custom", forked.source_kind
  assert_equal bundled.id, forked.forked_from_agent_program_id
  assert File.directory?(forked.absolute_local_path.join(".git"))
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/system_settings_agent_programs_test.rb test/system/system_settings_agent_programs_test.rb`

Expected: missing route/action/service and no git bootstrap.

**Step 3: Implement the fork service**

Implement a product-managed flow that:

- copies the bundled source tree into `RuntimeSetting.agent_workspace_root`
- rewrites the copied source identity to a new `agent_program_key` owned by the forked program
- initializes a git repository
- creates an initial commit and import tag
- creates a new `AgentProgram` with `source_kind: "custom"`
- provisions a normal `AgentDeployment` with its own generated runtime config and allocated endpoint

Keep Cybros out of ongoing git workflows after the initial bootstrap.

For milestone 1, this task must also close the main autonomy gap:

- in official local development and official compose flows, a forked agent must become runnable end-to-end, not merely generated-config-ready
- if unsupported deployment topologies still fall back to generated-config-ready, that fallback must be explicit and must not be used to claim milestone-1 completion

Add one direct integration proof and one browser proof for the fork path:

- `test/integration/forked_agent_execution_test.rb` should prove a forked agent can be selected for a conversation and complete one Cybros-owned agent loop through planning, finalization, and compose
- `test/e2e/bundled_agent_fork_flow.spec.ts` should prove the operator can fork the bundled default agent from settings, create a conversation with the forked agent, send one message, and observe a response through the forked deployment

**Step 4: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/system_settings_agent_programs_test.rb test/system/system_settings_agent_programs_test.rb test/integration/forked_agent_execution_test.rb`

Run: `bunx playwright test test/e2e/bundled_agent_fork_flow.spec.ts`

Expected: PASS.

**Step 5: Commit**

```bash
git add app/services/agent_programs/git_bootstrap.rb app/services/agent_programs/fork_service.rb config/routes.rb app/controllers/system/settings/agent_programs_controller.rb app/views/system/settings/agent_programs/index.html.erb app/views/system/settings/agent_programs/show.html.erb test/integration/system_settings_agent_programs_test.rb test/system/system_settings_agent_programs_test.rb test/integration/forked_agent_execution_test.rb test/e2e/bundled_agent_fork_flow.spec.ts
git commit -m "feat: add bundled agent fork flow"
```

### Task 7: Surface Deployment Lineage And Update Docs

**Files:**
- Modify: `app/views/system/settings/agent_deployments/index.html.erb`
- Modify: `app/views/system/settings/agent_deployments/show.html.erb`
- Modify: `app/controllers/system/settings/agent_deployments_controller.rb`
- Modify: `docs/product/programmable_agents.md`
- Modify: `docs/product/agent_contract.md`
- Modify: `docs/product/execution_model.md`
- Modify: `test/integration/agent_deployments_activation_gate_test.rb`
- Modify: `test/e2e/programmable_agent_registration.spec.ts`
- Modify: `test/e2e/settings.spec.ts`

**Step 1: Write the failing operator-surface tests**

Add assertions that the UI shows:

```ruby
assert_text "Official bundled agent"
assert_text "Forked from"
assert_text "Active deployment"
assert_text "Fingerprint"
assert_no_text "Built-in"
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/agent_deployments_activation_gate_test.rb`

Expected: current views/controllers do not expose bundled/custom lineage or hide the old builtin mental model.

**Step 3: Implement the surface cleanup**

Expose durable facts only:

- source kind
- bundled key or fork origin
- source path
- allocated endpoint / port
- generated runtime config path
- launch status / launch owner
- deployment health
- deployment fingerprint
- active deployment timestamp

Then refresh the product docs so they describe the bundled default external agent as the new default path.

Make the operator surfaces and docs match the milestone acceptance bar:

- the official bundled default agent is presented as the product default
- the bundled source is clearly a standalone program under `agents/default`
- nothing in the UI suggests the product still depends on a builtin or profile-only runtime
- follow-on reference classes remain challenge suites rather than silent implied promises

**Step 4: Run the focused tests and smoke the e2e specs**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/agent_deployments_activation_gate_test.rb`

Run: `bunx playwright test test/e2e/settings.spec.ts test/e2e/programmable_agent_registration.spec.ts`

Expected: Rails tests PASS; e2e specs pass once the dev host/process wiring is in place.

**Step 5: Commit**

```bash
git add app/views/system/settings/agent_deployments/index.html.erb app/views/system/settings/agent_deployments/show.html.erb app/controllers/system/settings/agent_deployments_controller.rb docs/product/programmable_agents.md docs/product/agent_contract.md docs/product/execution_model.md test/integration/agent_deployments_activation_gate_test.rb test/e2e/programmable_agent_registration.spec.ts test/e2e/settings.spec.ts
git commit -m "docs: rebaseline bundled external agent surfaces"
```

### Final Verification

Run the implementation branch through the targeted verification suite before claiming completion:

```bash
PARALLEL_WORKERS=1 bin/rails test \
  test/models/agent_program_test.rb \
  test/models/runtime_setting_test.rb \
  test/models/conversation_program_selection_test.rb \
  test/models/agent_deployment_test.rb \
  test/models/conversation_chat_facade_test.rb \
  test/integration/setup_and_sessions_test.rb \
  test/integration/agent_programs_test.rb \
  test/integration/system_settings_agent_programs_test.rb \
  test/integration/agent_deployments_registration_test.rb \
  test/integration/agent_deployments_inspection_test.rb \
  test/integration/agent_deployments_activation_gate_test.rb \
  test/integration/conversation_agent_program_selection_test.rb \
  test/integration/programmable_agent_execution_test.rb \
  test/integration/bundled_default_agent_execution_test.rb \
  test/integration/forked_agent_execution_test.rb \
  test/integration/system_settings_runtime_settings_test.rb \
  test/system/system_settings_runtime_settings_test.rb \
  test/system/system_settings_agent_programs_test.rb

bin/rails test test/models/agent_rpc_invocation_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/agent_rpc_activation_drift_test.rb

PARALLEL_WORKERS=1 bin/rails test test/services/agent_rpc/lifecycle_caller_test.rb test/integration/run_draft_finalization_test.rb test/lib/cybros/bundled_agent_host_test.rb

cd agents/default && bundle exec ruby -Itest test/unit/manifest_test.rb test/integration/rpc_contract_test.rb

bunx playwright test test/e2e/settings.spec.ts test/e2e/programmable_agent_registration.spec.ts test/e2e/programmable_agent_approval_resume.spec.ts test/e2e/programmable_agent_target_switch.spec.ts test/e2e/bundled_default_agent_flow.spec.ts test/e2e/bundled_agent_fork_flow.spec.ts
```

Expected:

- Rails targeted suites pass with `0 failures, 0 errors`
- programmable-agent replay/binding suites stay green
- the bundled default agent package tests pass as a standalone program
- deployment disconnect / stale-session behavior is covered explicitly
- e2e coverage confirms the default bundled path and fork path both run through the Cybros-owned loop, including approval-resume and target-switch edges
- milestone 1 acceptance is judged against general-assistant + light-coding behavior, while broader always-on / multi-surface general-agent expectations and the remaining reference classes are recorded as explicit post-cut challenge suites
