# Bundled Claw External Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Convert the bundled default `claw` runtime into a true external deployment across bare-metal and Docker flows, while keeping database-persisted runtime bindings as the only hot-path source of truth.

**Architecture:** Replace the in-process bundled host bootstrap with a bundled-default reconcile service that reads explicit bootstrap ENV inputs, writes the desired connection state into the `agents` row, and validates the external runtime through normal HTTP JSON-RPC inspection. Make the bundled default workspace path stable, wire `Procfile.dev` and Compose to run a separate `claw` process, and delete obsolete managed-local host recovery behavior.

**Tech Stack:** Ruby on Rails, ActiveSupport tests, WEBrick/Puma removal from app hot path, Foreman Procfile, Docker Compose, Playwright E2E, OpenRouter-backed E2E runtime.

---

### Task 1: Document the approved external-runtime design

**Files:**
- Create: `docs/plans/2026-03-16-bundled-claw-external-runtime-design.md`
- Create: `docs/plans/2026-03-16-bundled-claw-external-runtime.md`

**Step 1: Write the approved design doc**

Capture:

- external-runtime topology
- DB vs ENV source-of-truth rules
- bundled default special-case boundary
- stable workspace model
- `Procfile.dev` and Compose startup semantics
- failure and recovery semantics

**Step 2: Verify the docs exist**

Run: `test -f docs/plans/2026-03-16-bundled-claw-external-runtime-design.md && test -f docs/plans/2026-03-16-bundled-claw-external-runtime.md`

Expected: exit 0

### Task 2: Lock bootstrap behavior with failing tests

**Files:**
- Modify: `test/services/agents/bootstrap_bundled_default_service_test.rb`
- Modify: `test/models/agent_test.rb`
- Modify: `test/models/conversation_program_selection_test.rb`

**Step 1: Write failing bootstrap reconcile tests**

Add coverage proving:

- bundled bootstrap persists endpoint, bearer, and fingerprint from bootstrap ENV
- bundled bootstrap no longer starts or caches an in-process host
- bundled default workspace resolves to a stable bundled path instead of `claw-<agent.id>`

Example assertions:

```ruby
test "ensure_agent reconciles the bundled claw deployment from bootstrap env" do
  with_env(
    "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL" => "http://127.0.0.1:4242/rpc",
    "CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER" => "secret://bundled-claw:dev",
    "CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT" => "deployment:bundled-claw:dev"
  ) do
    agent = Agents::BootstrapBundledDefaultService.ensure_agent!

    assert_equal "http://127.0.0.1:4242/rpc", agent.endpoint_url
    assert_equal "secret://bundled-claw:dev", agent.deployment_bearer_secret_ref
    assert_equal "deployment:bundled-claw:dev", agent.deployment_fingerprint
  end
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb test/models/agent_test.rb test/models/conversation_program_selection_test.rb`

Expected: FAIL because bootstrap still starts the bundled host and workspace paths still include the agent ID.

### Task 3: Implement bundled-default runtime config resolution

**Files:**
- Create: `app/services/agents/bundled_default_runtime_config.rb`
- Modify: `app/services/agents/bootstrap_bundled_default_service.rb`
- Modify: `app/controllers/setups_controller.rb`
- Modify: `app/controllers/dashboard_controller.rb`

**Step 1: Write the minimal runtime-config resolver**

Implement an object that returns:

```ruby
{
  endpoint_url: ENV.fetch("CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL"),
  bearer: ENV.fetch("CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER"),
  fingerprint: ENV.fetch("CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT"),
  protocol_version: "agent_rpc.v1"
}
```

with narrow validation and clear exceptions when required values are missing.

**Step 2: Remove in-process bundled host behavior**

Delete from `BootstrapBundledDefaultService`:

- `HOST_MUTEX`
- `@hosts` cache
- `ensure_host!`
- `Cybros::BundledAgentHost::Application.new(...).start`

Replace with:

- create/update bundled `claw` row
- initialize workspace
- write runtime binding fields from the resolver
- run capability handshake and health/inspection checks against the external endpoint

**Step 3: Keep setup/dashboard bootstrap idempotent**

Make sure:

- setup still bootstraps the bundled default agent
- dashboard still ensures the bundled default agent exists
- repeated calls reconcile stale DB values to the current environment

**Step 4: Run focused tests**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb test/models/agent_test.rb test/models/conversation_program_selection_test.rb`

Expected: PASS

### Task 4: Make bundled workspace paths stable

**Files:**
- Modify: `app/models/runtime_setting.rb`
- Modify: `app/services/agents/workspace_path_resolver.rb`
- Modify: `app/services/agents/workspace_initializer.rb`
- Modify: `test/models/agent_test.rb`
- Modify: `test/models/conversation_program_selection_test.rb`
- Modify: `test/integration/bundled_default_agent_execution_test.rb`

**Step 1: Write a failing path test**

Add coverage proving bundled `claw` resolves to:

```ruby
RuntimeSetting.instance_agent_workspace_root_path.join("bundled", "claw")
```

instead of `claw-#{agent.id}`.

**Step 2: Run the focused test and verify failure**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/agent_test.rb test/models/conversation_program_selection_test.rb test/integration/bundled_default_agent_execution_test.rb`

Expected: FAIL with old `claw-<id>` path assertions.

**Step 3: Implement stable bundled-path resolution**

Use a bundled-only branch in runtime/workspace path resolution so:

- bundled default `claw` uses a stable path under `bundled/claw`
- other bundled keys can follow the same stable bundled subtree if needed
- custom agents keep their existing behavior

**Step 4: Re-run the focused tests**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/agent_test.rb test/models/conversation_program_selection_test.rb test/integration/bundled_default_agent_execution_test.rb`

Expected: PASS

### Task 5: Remove managed-local retry behavior

**Files:**
- Modify: `app/services/agents/rpc_client.rb`
- Modify: `test/integration/bundled_agent_parity_test.rb`
- Create: `test/services/agents/rpc_client_test.rb`

**Step 1: Write failing retry-behavior tests**

Prove:

- RPC retry no longer calls bootstrap to spawn a host
- recoverable connection errors surface as transport errors when the persisted endpoint is down

Example assertion:

```ruby
test "connection failures do not respawn bundled claw from the rpc client" do
  agent = agents(:bundled_claw)
  agent.update!(endpoint_url: "http://127.0.0.1:65535/rpc")

  assert_raises(Agents::RPCClient::TransportError) do
    Agents::RPCClient.new(agent: agent).call("agent.health")
  end
end
```

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/agents/rpc_client_test.rb test/integration/bundled_agent_parity_test.rb`

Expected: FAIL while the retry path still calls bundled bootstrap as a recovery hook.

**Step 3: Delete the managed-local refresh path**

Remove:

- `retry_with_refreshed_managed_local_claw_runtime!`
- `managed_local_claw_deployment?`

Keep the RPC client as a plain database-backed HTTP JSON-RPC caller.

**Step 4: Re-run the focused tests**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/agents/rpc_client_test.rb test/integration/bundled_agent_parity_test.rb`

Expected: PASS

### Task 6: Wire bare-metal startup through Procfile and `bin/dev`

**Files:**
- Modify: `Procfile.dev`
- Modify: `bin/dev`
- Create: `test/integration/dev_boot_flow_test.rb`

**Step 1: Write failing startup wiring tests**

Assert:

- `Procfile.dev` contains a `claw` entry
- the `claw` entry passes matching workspace/bearer/fingerprint settings
- `bin/dev` no longer relies on app-owned bundled host management to make the default runtime available

**Step 2: Run focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/dev_boot_flow_test.rb`

Expected: FAIL because `Procfile.dev` lacks a `claw` process and `bin/dev` still reflects the old split-launch shape.

**Step 3: Implement the startup wiring**

Set concrete development defaults such as:

- `CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL=http://127.0.0.1:4242/rpc`
- `CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER=secret://bundled-claw:dev`
- `CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT=deployment:bundled-claw:dev`
- `CLAW_REQUIRED_BEARER=secret://bundled-claw:dev`
- `CLAW_DEPLOYMENT_FINGERPRINT=deployment:bundled-claw:dev`
- `CLAW_WORKSPACE_ROOT=$PWD/tmp/agent-workspace/bundled/claw`

Add a `claw` process that starts `agents/claw/bin/rails server` on a fixed local port.

**Step 4: Re-run the focused test**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/dev_boot_flow_test.rb`

Expected: PASS

### Task 7: Wire Docker Compose through a dedicated `claw` service

**Files:**
- Modify: `compose.yaml.sample`
- Modify: `compose.yaml`
- Modify: `.devcontainer/compose.yaml`
- Modify: `test/lib/official_compose_template_test.rb`

**Step 1: Write failing Compose tests**

Assert:

- official Compose templates define a `claw` service
- `app` and `jobs` receive bundled bootstrap ENV pointing at the `claw` service URL
- the shared agent workspace volume is mounted into `claw`
- `claw` receives matching bearer/fingerprint/workspace settings

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/lib/official_compose_template_test.rb`

Expected: FAIL because the templates do not yet define a dedicated `claw` service.

**Step 3: Implement the Compose topology**

Add a `claw` service that:

- runs the `agents/claw` Rails app
- exposes the internal HTTP port to sibling services
- mounts the shared bundled workspace volume
- uses the same bearer/fingerprint values that `app` and `jobs` bootstrap into the DB

**Step 4: Re-run the focused tests**

Run: `PARALLEL_WORKERS=1 bin/rails test test/lib/official_compose_template_test.rb`

Expected: PASS

### Task 8: Keep standalone `agents/claw` compatible with the new wiring

**Files:**
- Modify: `agents/claw/lib/cybros/agents/claw/application.rb`
- Modify: `agents/claw/app/controllers/rpc_controller.rb`
- Modify: `agents/claw/test/integration/rpc_contract_test.rb`
- Modify: `agents/claw/test/requests/http_boundary_test.rb`

**Step 1: Write failing standalone-runtime tests**

Add coverage proving the Rails `claw` app can read:

- `CLAW_REQUIRED_BEARER`
- `CLAW_DEPLOYMENT_FINGERPRINT`
- `CLAW_WORKSPACE_ROOT`

and applies them at the HTTP boundary and runtime identity.

**Step 2: Run the focused tests to verify they fail**

Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb && bundle exec ruby -Itest agents/claw/test/requests/http_boundary_test.rb`

Expected: FAIL because workspace-root support is not yet plumbed from ENV into the app boundary.

**Step 3: Implement the minimal runtime plumbing**

Ensure the app boundary instantiates `Cybros::Agents::Claw::Application` with the configured workspace root and that bearer validation still happens strictly at the HTTP layer.

**Step 4: Re-run the focused tests**

Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb && bundle exec ruby -Itest agents/claw/test/requests/http_boundary_test.rb`

Expected: PASS

### Task 9: Clean up dead bundled-host code and stale assertions

**Files:**
- Delete: `lib/cybros/bundled_agent_host/application.rb`
- Delete: `lib/cybros/bundled_agent_host/router.rb`
- Modify: `test/lib/cybros/bundled_agent_host_test.rb`
- Modify: `test/integration/bundled_agent_parity_test.rb`
- Modify: docs that still describe managed-local bundled host behavior if touched by tests

**Step 1: Write failing cleanup tests**

Replace old host-behavior assertions with new expectations around standalone `agents/claw` identity and source-root contract.

**Step 2: Run the focused tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/lib/cybros/bundled_agent_host_test.rb test/integration/bundled_agent_parity_test.rb`

Expected: FAIL because old tests still reference the deleted host path.

**Step 3: Remove dead code and rewrite the tests**

Delete the unused bundled-host runtime layer and update tests to target the external-runtime architecture.

**Step 4: Re-run the focused tests**

Run: `PARALLEL_WORKERS=1 bin/rails test test/lib/cybros/bundled_agent_host_test.rb test/integration/bundled_agent_parity_test.rb`

Expected: PASS

### Task 10: Verify full Rails test coverage for the changed runtime path

**Files:**
- Modify: any tests that still encode the old managed-local semantics

**Step 1: Run the targeted Rails suite**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb test/services/agents/rpc_client_test.rb test/models/agent_test.rb test/models/conversation_program_selection_test.rb test/integration/bundled_default_agent_execution_test.rb test/integration/dev_boot_flow_test.rb test/lib/official_compose_template_test.rb test/integration/bundled_agent_parity_test.rb`

Expected: all PASS

**Step 2: Run the standalone `claw` suite**

Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb && bundle exec ruby -Itest agents/claw/test/requests/http_boundary_test.rb`

Expected: PASS

### Task 11: Verify interactive and end-to-end flows

**Files:**
- No planned file changes; fix any failures discovered here

**Step 1: Verify browser E2E against local `bin/dev`**

Run: `bin/e2e`

Expected: PASS

**Step 2: Verify CI-flavored local E2E**

Run: `bin/ci_e2e`

Expected: PASS

**Step 3: Verify bare-metal manually**

Run:

```bash
bin/dev
```

Manually confirm:

- `web`, `job`, `js`, `css`, and `claw` all boot
- setup succeeds
- bundled default `claw` becomes selectable/active
- a real conversation turn completes through the external `claw` runtime

**Step 4: Verify Docker Compose manually**

Run:

```bash
docker compose -f compose.yaml.sample up --build
```

Manually confirm:

- `app`, `jobs`, and `claw` all become healthy or ready
- setup succeeds in the browser
- the bundled default `claw` runtime works end-to-end through the Compose network

### Task 12: Final verification and cleanup

**Files:**
- Modify: anything required by final verification failures

**Step 1: Run the main CI suite**

Run: `bin/ci`

Expected: PASS

**Step 2: Re-run the E2E suite after final fixes**

Run: `bin/e2e && bin/ci_e2e`

Expected: PASS

**Step 3: Check for dead managed-local references**

Run: `rg -n "managed-local|BundledAgentHost|ensure_host!|retry_with_refreshed_managed_local_claw_runtime|@hosts|HOST_MUTEX" .`

Expected: only intentional historical docs or archived references remain

**Step 4: If schema or seeded runtime state became invalid during the refactor, reset the database**

Run: `bin/rails db:reset`

Expected: schema reload succeeds and setup/bootstrap still works with the new external runtime flow
