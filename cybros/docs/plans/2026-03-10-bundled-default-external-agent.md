# Bundled Default External Agent Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the builtin conversation-agent runtime with a bundled default external programmable agent, then add a copy-as-custom workflow that preserves capability parity, restart safety, and per-deployment endpoint isolation.

**Architecture:** Add explicit bundled/custom source ownership to `AgentProgram`, ship a real bundled default agent plus an out-of-process companion host, generate deployment-specific runtime config with allocated endpoints and bearer credentials, bootstrap a default program/deployment during setup, delete the builtin conversation fallback, and add a product-managed fork flow that copies source into a user-owned git repository and provisions a normal deployment.

**Tech Stack:** Ruby on Rails, ActiveRecord migrations, Hotwire/ERB, JSON-RPC `agent_rpc`, git CLI, Procfile.dev, Docker Compose

---

### Task 1: Model Source Ownership And Workspace Root

**Files:**
- Create: `db/migrate/20260310100000_add_agent_source_fields_and_workspace_root.rb`
- Modify: `app/models/agent_program.rb`
- Modify: `app/models/runtime_setting.rb`
- Modify: `app/controllers/system/settings/runtime_settings_controller.rb`
- Modify: `app/views/system/settings/runtime_settings/_form.html.erb`
- Modify: `app/views/system/settings/runtime_settings/show.html.erb`
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
    local_path: "agents/default-assistant"
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
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/agent_program_test.rb test/models/runtime_setting_test.rb test/integration/system_settings_runtime_settings_test.rb test/system/system_settings_runtime_settings_test.rb`

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

Keep the first pass narrow: only add the fields, validations, controller coercion, and settings UI.

**Step 4: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/agent_program_test.rb test/models/runtime_setting_test.rb test/integration/system_settings_runtime_settings_test.rb test/system/system_settings_runtime_settings_test.rb`

Expected: PASS.

**Step 5: Commit**

```bash
git add db/migrate/20260310100000_add_agent_source_fields_and_workspace_root.rb app/models/agent_program.rb app/models/runtime_setting.rb app/controllers/system/settings/runtime_settings_controller.rb app/views/system/settings/runtime_settings/_form.html.erb app/views/system/settings/runtime_settings/show.html.erb test/models/agent_program_test.rb test/models/runtime_setting_test.rb test/integration/system_settings_runtime_settings_test.rb test/system/system_settings_runtime_settings_test.rb
git commit -m "feat: model bundled agent source ownership"
```

### Task 2: Ship The Bundled Default Agent Package And External Host

**Files:**
- Create: `agents/default-assistant/agent.yml`
- Create: `agents/default-assistant/README.md`
- Create: `bin/default_agent_host`
- Create: `lib/cybros/bundled_agent_host/application.rb`
- Create: `lib/cybros/bundled_agent_host/router.rb`
- Create: `app/services/agent_programs/bundled_sources.rb`
- Modify: `app/services/agent_programs/creator.rb`
- Modify: `app/services/agent_programs/loader.rb`
- Delete: `agents/profiles/default-assistant/agent.yml`
- Test: `test/integration/agent_programs_test.rb`
- Test: `test/integration/agent_deployments_inspection_test.rb`
- Test: `test/lib/cybros/bundled_agent_host_test.rb`

**Step 1: Write the failing bundled-source and host tests**

Add tests that prove:

```ruby
test "bundled source registry exposes default assistant" do
  assert_includes AgentPrograms::BundledSources.available_keys, "default-assistant"
end

test "default agent host responds to required methods" do
  host = Cybros::BundledAgentHost::Application.new(source_root: Rails.root.join("agents/default-assistant"))

  assert_includes host.supported_methods, "initialize"
  assert_includes host.supported_methods, "turn.prepare"
  assert_includes host.supported_methods, "turn.compose"
  assert_includes host.supported_methods, "turn.handle_error"
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/agent_programs_test.rb test/integration/agent_deployments_inspection_test.rb test/lib/cybros/bundled_agent_host_test.rb`

Expected: missing files/constants and failing expectations around bundled-source discovery and required RPC methods.

**Step 3: Implement the external host and source registry**

Land the first milestone as:

- `agents/default-assistant/agent.yml` describes the official bundled agent source
- `bin/default_agent_host` boots a standalone Ruby process
- `lib/cybros/bundled_agent_host/**` serves the required `agent_rpc` methods
- `AgentPrograms::BundledSources` replaces bundled-profile discovery
- `AgentPrograms::Creator` can create programs from bundled sources, not only copied no-op profiles

Use the current programmable-agent fixture behavior as the contract floor, not as a hidden runtime path.

**Step 4: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/agent_programs_test.rb test/integration/agent_deployments_inspection_test.rb test/lib/cybros/bundled_agent_host_test.rb`

Expected: PASS.

**Step 5: Commit**

```bash
git add agents/default-assistant/agent.yml agents/default-assistant/README.md bin/default_agent_host lib/cybros/bundled_agent_host/application.rb lib/cybros/bundled_agent_host/router.rb app/services/agent_programs/bundled_sources.rb app/services/agent_programs/creator.rb app/services/agent_programs/loader.rb test/integration/agent_programs_test.rb test/integration/agent_deployments_inspection_test.rb test/lib/cybros/bundled_agent_host_test.rb
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
- Test: `test/models/agent_deployment_test.rb`
- Test: `test/integration/agent_deployments_registration_test.rb`
- Test: `test/integration/agent_deployments_activation_gate_test.rb`

**Step 1: Write the failing endpoint-allocation and restart-safety tests**

Add assertions like:

```ruby
test "registration allocates a unique port and writes runtime config" do
  program = agent_programs(:default_assistant)

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

test "activation does not deactivate the old deployment before the new one is healthy" do
  old_deployment = agent_deployments(:active_default_assistant)
  new_deployment = agent_deployments(:inactive_default_assistant_candidate)

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

Keep the owner boundary clear:

- source tree owns agent code and static source config
- `transport_config` and generated runtime config own live endpoint binding

**Step 4: Harden cutover rules**

Make sure activation semantics remain:

- inspect first
- require matching identity and healthy status
- only deactivate the old deployment after the new one is ready
- never let an in-flight run silently reconnect to a replacement process on the same port

**Step 5: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/agent_deployment_test.rb test/integration/agent_deployments_registration_test.rb test/integration/agent_deployments_activation_gate_test.rb`

Expected: PASS.

**Step 6: Commit**

```bash
git add app/services/agent_deployments/endpoint_allocator.rb app/services/agent_deployments/runtime_config_writer.rb app/services/agent_deployments/registration_service.rb app/services/agent_deployments/inspection_service.rb app/services/agent_deployments/activation_service.rb app/models/agent_deployment.rb test/models/agent_deployment_test.rb test/integration/agent_deployments_registration_test.rb test/integration/agent_deployments_activation_gate_test.rb
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
- Test: `test/integration/setup_and_sessions_test.rb`
- Test: `test/integration/agent_deployments_registration_test.rb`
- Test: `test/e2e/settings.spec.ts`

**Step 1: Write the failing bootstrap tests**

Add assertions like:

```ruby
test "setup bootstraps the bundled default program and active deployment" do
  post setup_path, params: { identity: { email: "owner@example.com", password: "Passw0rd", password_confirmation: "Passw0rd" } }

  program = AgentProgram.find_by!(bundled_agent_key: "default-assistant")
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

Then wire it into:

- `SetupsController#create`
- `Procfile.dev` so the host starts in local development
- `compose.yaml.sample` and `.devcontainer/compose.yaml` so the host is present in container flows

**Step 4: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/setup_and_sessions_test.rb test/integration/agent_deployments_registration_test.rb`

Expected: PASS.

**Step 5: Commit**

```bash
git add app/services/agent_programs/bootstrap_bundled_default_service.rb app/controllers/setups_controller.rb Procfile.dev compose.yaml.sample .devcontainer/compose.yaml test/e2e/helpers.ts test/integration/setup_and_sessions_test.rb test/integration/agent_deployments_registration_test.rb test/e2e/settings.spec.ts
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
  program = AgentProgram.find_by!(bundled_agent_key: "default-assistant")

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
- Test: `test/integration/system_settings_agent_programs_test.rb`
- Test: `test/system/system_settings_agent_programs_test.rb`

**Step 1: Write the failing fork-flow tests**

Add coverage like:

```ruby
test "copy as custom agent creates a forked program and git repo" do
  bundled = AgentProgram.find_by!(bundled_agent_key: "default-assistant")

  post fork_system_settings_agent_program_path(bundled), params: { name: "My assistant" }

  forked = AgentProgram.find_by!(name: "My assistant")
  assert_equal "custom", forked.source_kind
  assert_equal bundled.id, forked.forked_from_agent_program_id
  assert File.directory?(Rails.root.join(forked.local_path, ".git"))
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/system_settings_agent_programs_test.rb test/system/system_settings_agent_programs_test.rb`

Expected: missing route/action/service and no git bootstrap.

**Step 3: Implement the fork service**

Implement a product-managed flow that:

- copies the bundled source tree into `RuntimeSetting.agent_workspace_root`
- initializes a git repository
- creates an initial commit and import tag
- creates a new `AgentProgram` with `source_kind: "custom"`
- provisions a normal `AgentDeployment` with its own generated runtime config and allocated endpoint

Keep Cybros out of ongoing git workflows after the initial bootstrap.

**Step 4: Run the focused tests again**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/system_settings_agent_programs_test.rb test/system/system_settings_agent_programs_test.rb`

Expected: PASS.

**Step 5: Commit**

```bash
git add app/services/agent_programs/git_bootstrap.rb app/services/agent_programs/fork_service.rb config/routes.rb app/controllers/system/settings/agent_programs_controller.rb app/views/system/settings/agent_programs/index.html.erb app/views/system/settings/agent_programs/show.html.erb test/integration/system_settings_agent_programs_test.rb test/system/system_settings_agent_programs_test.rb
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
- deployment health
- deployment fingerprint
- active deployment timestamp

Then refresh the product docs so they describe the bundled default external agent as the new default path.

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
  test/models/agent_deployment_test.rb \
  test/models/conversation_chat_facade_test.rb \
  test/integration/setup_and_sessions_test.rb \
  test/integration/agent_programs_test.rb \
  test/integration/system_settings_agent_programs_test.rb \
  test/integration/agent_deployments_registration_test.rb \
  test/integration/agent_deployments_inspection_test.rb \
  test/integration/agent_deployments_activation_gate_test.rb \
  test/integration/conversation_agent_program_selection_test.rb \
  test/integration/system_settings_runtime_settings_test.rb \
  test/system/system_settings_runtime_settings_test.rb \
  test/system/system_settings_agent_programs_test.rb

bin/rails test test/models/agent_rpc_invocation_test.rb test/integration/agent_rpc_invocation_replay_test.rb test/integration/agent_rpc_activation_drift_test.rb

bunx playwright test test/e2e/settings.spec.ts test/e2e/programmable_agent_registration.spec.ts
```

Expected:

- Rails targeted suites pass with `0 failures, 0 errors`
- programmable-agent replay/binding suites stay green
- e2e coverage confirms the default external agent and fork flow in the UI
