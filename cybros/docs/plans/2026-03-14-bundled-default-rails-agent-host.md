# Bundled Default Rails Agent Host Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the bundled default agent's WEBrick host by promoting the Rails skeleton in `cybros/vendor/agents/claw` into the canonical bundled source tree, then complete a second cutover that renames the bundled agent identity and source root from `default` to `claw`, while preserving the existing `agent_rpc.v1` HTTP JSON-RPC contract and callback-session behavior.

**Architecture:** Use `cybros/vendor/agents/claw` as the seed Rails scaffold instead of building a Rails app from scratch in place. First cut over the host by promoting that scaffold into `cybros/agents/default` while preserving runtime identity `default`; then run a separate rename phase that moves the canonical source root to `cybros/agents/claw` and changes the bundled identity to `claw`. Keep `ActiveRecord` / `ActiveJob` available but off the request hot path.

**Tech Stack:** Ruby, Rails API-only app, Puma, JSON-RPC over HTTP, current bundled-agent manifest/prompt assets, Minitest, Net::HTTP

---

### Task 1: Lock The External Contract Before Replacing The Host

**Files:**
- Modify: `cybros/agents/default/test/integration/rpc_contract_test.rb`
- Modify: `cybros/agents/default/test/unit/manifest_test.rb`
- Modify: `cybros/agents/default/test/test_helper.rb`

**Step 1: Write the failing test**

Add contract coverage for:

- `POST /rpc` remains the only canonical RPC route
- `GET /health` returns identity-bearing health payload
- invalid bearer returns an auth failure instead of executing handler logic
- malformed JSON returns a stable parse/protocol error
- unknown methods still return method-not-found behavior

Example test shape:

```ruby
def test_post_rpc_rejects_unknown_method
  host = build_host.start
  payload = rpc_json(host.rpc_url, id: 99, method: "unknown.method", params: {})

  assert_equal -32601, payload.dig("error", "code")
end
```

**Step 2: Run test to verify it fails**

Run: `cd cybros/agents/default && bin/test`

Expected: FAIL because the current contract coverage is incomplete and the new boundary assertions are not implemented yet.

**Step 3: Write minimal implementation**

Only add/adjust test helpers and assertions needed to describe the frozen external contract.
Do not start moving host code yet.

**Step 4: Run test to verify it passes**

Run: `cd cybros/agents/default && bin/test`

Expected: PASS with the old host still in place and the contract frozen by tests.

**Step 5: Commit**

```bash
git add cybros/agents/default/test/integration/rpc_contract_test.rb cybros/agents/default/test/unit/manifest_test.rb cybros/agents/default/test/test_helper.rb
git commit -m "test: lock bundled agent http contract"
```

### Task 2: Promote The `claw` Rails Skeleton Into `cybros/agents/default`

**Files:**
- Create: `cybros/agents/default/app/controllers/application_controller.rb`
- Create: `cybros/agents/default/config/application.rb`
- Create: `cybros/agents/default/config/boot.rb`
- Create: `cybros/agents/default/config/environment.rb`
- Create: `cybros/agents/default/config/environments/development.rb`
- Create: `cybros/agents/default/config/environments/test.rb`
- Create: `cybros/agents/default/config/environments/production.rb`
- Create: `cybros/agents/default/config/routes.rb`
- Create: `cybros/agents/default/config/puma.rb`
- Create: `cybros/agents/default/config/initializers/filter_parameter_logging.rb`
- Create: `cybros/agents/default/config.ru`
- Create: `cybros/agents/default/bin/rails`
- Create: `cybros/agents/default/test/integration/http_boundary_test.rb`
- Modify: `cybros/agents/default/Gemfile`
- Modify: `cybros/agents/default/Gemfile.lock`
- Modify: `cybros/agents/default/Rakefile`
- Modify: `cybros/agents/default/bin/server`
- Modify: `cybros/agents/default/bin/test`
- Modify: `cybros/agents/default/test/test_helper.rb`
- Delete: `cybros/vendor/agents/claw`

**Step 1: Write the failing test**

Add/request-level tests that expect Rails routes to exist:

- `POST /rpc`
- `GET /health`

Example controller expectation:

```ruby
post "/rpc", params: JSON.generate(payload), headers: { "CONTENT_TYPE" => "application/json" }
assert_response :success
```

**Step 2: Run test to verify it fails**

Run: `cd cybros/agents/default && bundle exec rails test test/integration/http_boundary_test.rb`

Expected: FAIL because the canonical bundled source tree has not yet been promoted to a Rails app.

**Step 3: Write minimal implementation**

Promote the existing `cybros/vendor/agents/claw` skeleton into `cybros/agents/default`:

- copy only the Rails host files that are actually needed
- keep Puma as the app server
- expose `/rpc` and `/health`
- wire `bin/server` and `bin/test` to the promoted Rails app
- switch `test/test_helper.rb` to boot the promoted Rails test environment
- remove the temporary `cybros/vendor/agents/claw` tree once the promoted files exist in `cybros/agents/default`

Minimal route shape:

```ruby
Rails.application.routes.draw do
  post "/rpc", to: "rpc#create"
  get "/health", to: "health#show"
end
```

**Step 4: Run test to verify it passes**

Run: `cd cybros/agents/default && bundle exec rails test test/integration/http_boundary_test.rb`

Expected: PASS with Rails booting and the two endpoints present.

**Step 5: Commit**

```bash
git add cybros/agents/default/app/controllers/application_controller.rb cybros/agents/default/config/application.rb cybros/agents/default/config/boot.rb cybros/agents/default/config/environment.rb cybros/agents/default/config/environments/development.rb cybros/agents/default/config/environments/test.rb cybros/agents/default/config/environments/production.rb cybros/agents/default/config/routes.rb cybros/agents/default/config/puma.rb cybros/agents/default/config/initializers/filter_parameter_logging.rb cybros/agents/default/config.ru cybros/agents/default/bin/rails cybros/agents/default/test/integration/http_boundary_test.rb cybros/agents/default/test/test_helper.rb cybros/agents/default/Gemfile cybros/agents/default/Gemfile.lock cybros/agents/default/Rakefile cybros/agents/default/bin/server cybros/agents/default/bin/test
git rm -r cybros/vendor/agents/claw
git commit -m "feat: promote claw rails scaffold into bundled default"
```

### Task 3: Port The Existing Bundled Default Runtime Core Into The Promoted Rails Host

**Files:**
- Modify: `cybros/agents/default/lib/cybros/agents/default/application.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/rpc_dispatcher.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/manifest.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/identity.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/hooks/before_agent_step.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/hooks/before_finalize_output.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/hooks/on_conversation_created.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/hooks/on_lane_first_user_message.rb`

**Step 1: Write the failing test**

Add unit coverage proving the application core can be instantiated and used without a live Rails request:

- manifest loading still works from source root
- identity payload is stable
- dispatcher returns the same shapes for `initialize`, `agent.health`, and hook methods

Example unit shape:

```ruby
app = Cybros::Agents::Default::Application.new(source_root: TestPaths.source_root)
result = app.call(method_name: "agent.health", params: {})
assert_equal true, result.fetch("healthy")
```

**Step 2: Run test to verify it fails**

Run: `cd cybros/agents/default && bundle exec ruby -Itest test/unit/manifest_test.rb test/integration/rpc_contract_test.rb`

Expected: FAIL because the promoted Rails host does not yet carry over the existing bundled default runtime behavior.

**Step 3: Write minimal implementation**

Refactor only enough to make the core Rails-host-agnostic:

- `Application` becomes the runtime object, not the web server
- dispatcher and hooks stay pure Ruby
- callback HTTP calls remain encapsulated inside the hook/application layer

Example runtime boundary:

```ruby
def call(method_name:, params:)
  RPCDispatcher.new(application: self).dispatch(method_name: method_name, params: params)
end
```

**Step 4: Run test to verify it passes**

Run: `cd cybros/agents/default && bin/test`

Expected: PASS with core behavior matching the pre-Rails host output.

**Step 5: Commit**

```bash
git add cybros/agents/default/lib/cybros/agents/default/application.rb cybros/agents/default/lib/cybros/agents/default/rpc_dispatcher.rb cybros/agents/default/lib/cybros/agents/default/manifest.rb cybros/agents/default/lib/cybros/agents/default/identity.rb cybros/agents/default/lib/cybros/agents/default/hooks/before_agent_step.rb cybros/agents/default/lib/cybros/agents/default/hooks/before_finalize_output.rb cybros/agents/default/lib/cybros/agents/default/hooks/on_conversation_created.rb cybros/agents/default/lib/cybros/agents/default/hooks/on_lane_first_user_message.rb
git commit -m "refactor: keep bundled agent core host-agnostic"
```

### Task 4: Implement Thin Rails Controllers With Stable JSON-RPC Error Mapping

**Files:**
- Create: `cybros/agents/default/app/controllers/rpc_controller.rb`
- Create: `cybros/agents/default/app/controllers/health_controller.rb`
- Create: `cybros/agents/default/app/controllers/concerns/json_rpc_error_renderer.rb`
- Create: `cybros/agents/default/test/controllers/rpc_controller_test.rb`
- Create: `cybros/agents/default/test/controllers/health_controller_test.rb`

**Step 1: Write the failing test**

Cover:

- bearer validation happens at the boundary
- valid RPC requests delegate to the runtime object
- parse errors return JSON-RPC error payloads
- missing/unsupported methods return stable protocol errors
- `/health` returns a non-Rails-branded payload with `ok`, `status`, and `identity`

Example controller path:

```ruby
post "/rpc",
  params: "{",
  headers: { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer token" }

assert_response :bad_request
```

**Step 2: Run test to verify it fails**

Run: `cd cybros/agents/default && bundle exec rails test test/controllers/rpc_controller_test.rb test/controllers/health_controller_test.rb`

Expected: FAIL because controller behavior and error mapping are not implemented yet.

**Step 3: Write minimal implementation**

Make controllers thin:

- build a runtime instance
- parse request
- delegate to `application.call`
- serialize `result`
- map exceptions to JSON-RPC error responses

Minimal controller sketch:

```ruby
result = runtime.call(method_name: payload.fetch("method"), params: payload.fetch("params", {}))
render json: { jsonrpc: "2.0", id: payload.fetch("id"), result: result }
```

**Step 4: Run test to verify it passes**

Run: `cd cybros/agents/default && bundle exec rails test test/controllers/rpc_controller_test.rb test/controllers/health_controller_test.rb`

Expected: PASS with stable HTTP and JSON-RPC behavior.

**Step 5: Commit**

```bash
git add cybros/agents/default/app/controllers/rpc_controller.rb cybros/agents/default/app/controllers/health_controller.rb cybros/agents/default/app/controllers/concerns/json_rpc_error_renderer.rb cybros/agents/default/test/controllers/rpc_controller_test.rb cybros/agents/default/test/controllers/health_controller_test.rb
git commit -m "feat: add rails rpc boundary for bundled agent"
```

### Task 5: Replace WEBrick Bootstrapping With Puma-Backed Testable Host Startup

**Files:**
- Delete: `cybros/agents/default/lib/cybros/agents/default/rpc_server.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/application.rb`
- Modify: `cybros/agents/default/bin/server`
- Modify: `cybros/agents/default/test/support/callback_harness.rb`
- Modify: `cybros/agents/default/test/integration/rpc_contract_test.rb`
- Modify: `cybros/agents/default/README.md`

**Step 1: Write the failing test**

Add startup coverage proving:

- the bundled agent can boot under Puma on an ephemeral port
- tests can discover the bound `/rpc` URL
- the contract suite no longer depends on WEBrick internals

Example startup expectation:

```ruby
host = build_host.start
assert_match %r{\Ahttp://127\.0\.0\.1:\d+/rpc\z}, host.rpc_url
```

**Step 2: Run test to verify it fails**

Run: `cd cybros/agents/default && bin/test`

Expected: FAIL because startup still relies on `RPCServer` and WEBrick-specific plumbing.

**Step 3: Write minimal implementation**

Replace the old server wrapper with a Puma-backed launcher that still gives tests a small host object exposing:

- `start`
- `shutdown`
- `rpc_url`

Keep the launcher outside controller logic so tests and CLI share the same boot path.

**Step 4: Run test to verify it passes**

Run: `cd cybros/agents/default && bin/test`

Expected: PASS with no WEBrick dependency left in the bundled agent host.

**Step 5: Commit**

```bash
git add cybros/agents/default/lib/cybros/agents/default/application.rb cybros/agents/default/bin/server cybros/agents/default/test/support/callback_harness.rb cybros/agents/default/test/integration/rpc_contract_test.rb cybros/agents/default/README.md
git rm cybros/agents/default/lib/cybros/agents/default/rpc_server.rb
git commit -m "refactor: run bundled agent on puma"
```

### Task 6: Verify Cybros-Side Compatibility And Document The Cutover

**Files:**
- Modify: `cybros/docs/product/agent_rpc.md`
- Modify: `cybros/docs/plans/2026-03-14-bundled-default-rails-agent-host-design.md`
- Create: `cybros/test/integration/bundled_default_agent_host_cutover_test.rb`
- Modify: `cybros/test/integration/agent_runtime_binding_cutover_test.rb`

**Step 1: Write the failing test**

Cover:

- Cybros still treats the bundled default agent as `http_jsonrpc`
- recognized deployment and runtime binding continue to work unchanged
- no ActionCable/WebSocket transport is required for the bundled agent path

Example assertion:

```ruby
assert_equal "http_jsonrpc", deployment.transport_kind
assert_match %r{/rpc\z}, deployment.endpoint_url
```

**Step 2: Run test to verify it fails**

Run: `cd cybros && bin/rails test test/integration/bundled_default_agent_host_cutover_test.rb test/integration/agent_runtime_binding_cutover_test.rb`

Expected: FAIL until the product docs/tests are updated to the new host implementation and cutover assumptions.

**Step 3: Write minimal implementation**

Update docs and any remaining test fixtures so the product describes the bundled default agent as:

- first-party code under `cybros/agents/default`
- Rails/Puma hosted
- still speaking `agent_rpc.v1` over HTTP JSON-RPC
- seeded from the former `claw` scaffold while preserving bundled identity `default`

**Step 4: Run test to verify it passes**

Run: `cd cybros && bin/rails test test/integration/bundled_default_agent_host_cutover_test.rb test/integration/agent_runtime_binding_cutover_test.rb`

Expected: PASS with product/runtime expectations aligned to the new host.

**Step 5: Commit**

```bash
git add cybros/docs/product/agent_rpc.md cybros/docs/plans/2026-03-14-bundled-default-rails-agent-host-design.md cybros/test/integration/bundled_default_agent_host_cutover_test.rb cybros/test/integration/agent_runtime_binding_cutover_test.rb
git commit -m "docs: align bundled agent host cutover"
```

### Task 7: Rename Bundled Identity And Source Root From `default` To `claw`

**Files:**
- Move: `cybros/agents/default` -> `cybros/agents/claw`
- Move: `cybros/agents/claw/lib/cybros/agents/default.rb` -> `cybros/agents/claw/lib/cybros/agents/claw.rb`
- Move: `cybros/agents/claw/lib/cybros/agents/default` -> `cybros/agents/claw/lib/cybros/agents/claw`
- Modify: `cybros/agents/claw/agent.yml`
- Modify: `cybros/agents/claw/bin/server`
- Modify: `cybros/agents/claw/bin/test`
- Modify: `cybros/agents/claw/bin/console`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/application.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/identity.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/manifest.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/rpc_dispatcher.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/before_finalize_output.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/after_task_notice.rb`
- Modify: `cybros/agents/claw/prompts/AGENT.md`
- Modify: `cybros/agents/claw/README.md`
- Modify: `cybros/agents/claw/test/test_helper.rb`
- Modify: `cybros/agents/claw/test/unit/manifest_test.rb`
- Modify: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Modify: `cybros/app/services/agents/bundled_sources.rb`
- Modify: `cybros/app/services/agents/bootstrap_bundled_default_service.rb`
- Modify: `cybros/app/services/conversations/attachment_transfer_service.rb`
- Modify: `cybros/app/models/agent.rb`
- Modify: `cybros/app/controllers/dashboard_controller.rb`
- Modify: `cybros/test/services/agents/bootstrap_bundled_default_service_test.rb`
- Modify: `cybros/test/integration/agent_runtime_binding_cutover_test.rb`
- Modify: `cybros/test/integration/setup_and_sessions_test.rb`
- Modify: `cybros/test/integration/default_agent_attachment_transfer_test.rb`
- Modify: `cybros/test/integration/bundled_default_agent_execution_test.rb`
- Modify: `cybros/test/integration/programmable_agent_capabilities_handshake_test.rb`
- Modify: `cybros/docs/plans/2026-03-14-bundled-default-rails-agent-host-design.md`

**Step 1: Write the failing test**

Cover:

- bundled source resolution now resolves `claw`
- bootstrap provisions a bundled agent with `bundled_agent_key == "claw"`
- the canonical bundled source path is `cybros/agents/claw`
- the bundled-implementation special cases no longer check hard-coded `"default"`
- the promoted Rails host still boots and handshakes after the rename

Example assertion:

```ruby
agent = Agents::BootstrapBundledDefaultService.bootstrap!
assert_equal "claw", agent.bundled_agent_key
assert_equal Rails.root.join("agents", "claw").to_s, agent.absolute_local_path.to_s
```

**Step 2: Run test to verify it fails**

Run: `cd cybros && bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb test/integration/agent_runtime_binding_cutover_test.rb test/integration/setup_and_sessions_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/programmable_agent_capabilities_handshake_test.rb`

Expected: FAIL because the product and bundled source registry still hard-code `default`.

**Step 3: Write minimal implementation**

Implement the explicit rename phase:

- move the canonical bundled source tree to `cybros/agents/claw`
- rename the bundled Ruby entrypoint and module path from `Cybros::Agents::Default` to `Cybros::Agents::Claw`
- update bundled source resolution from `default` to `claw`
- update manifest identity fields, config namespace, capability labels, deployment fingerprints, and user-facing name
- update prompt text and runtime-generated copy that still says "Bundled default"
- replace hard-coded `bundled_agent_key == "default"` checks with either `claw` or a less identity-specific predicate where appropriate
- keep the protocol shape unchanged even though runtime identity strings change

**Step 4: Run test to verify it passes**

Run: `cd cybros && bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb test/integration/agent_runtime_binding_cutover_test.rb test/integration/setup_and_sessions_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/programmable_agent_capabilities_handshake_test.rb`

Expected: PASS with the bundled agent now identified as `claw`.

**Step 5: Commit**

```bash
git add cybros/agents/claw cybros/app/services/agents/bundled_sources.rb cybros/app/services/agents/bootstrap_bundled_default_service.rb cybros/app/services/conversations/attachment_transfer_service.rb cybros/app/models/agent.rb cybros/app/controllers/dashboard_controller.rb cybros/test/services/agents/bootstrap_bundled_default_service_test.rb cybros/test/integration/agent_runtime_binding_cutover_test.rb cybros/test/integration/setup_and_sessions_test.rb cybros/test/integration/default_agent_attachment_transfer_test.rb cybros/test/integration/bundled_default_agent_execution_test.rb cybros/test/integration/programmable_agent_capabilities_handshake_test.rb cybros/docs/plans/2026-03-14-bundled-default-rails-agent-host-design.md
git rm -r cybros/agents/default
git commit -m "refactor: rename bundled default agent to claw"
```

### Task 8: Run Final Verification Before Merge

**Files:**
- Modify: `cybros/agents/claw/bin/test`
- Modify: `cybros/bin/ci` 

**Step 1: Write the failing test**

Add/adjust the verification entrypoints so the bundled-agent contract suite is part of normal validation.

Example shell expectation:

```bash
cd cybros/agents/claw && bin/test
cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/integration/agent_runtime_binding_cutover_test.rb
```

**Step 2: Run test to verify it fails**

Run: `cd cybros/agents/claw && bin/test`

Expected: FAIL if any host-replacement contract drift remains.

**Step 3: Write minimal implementation**

Make the verification commands the canonical way to prove:

- bundled-agent contract parity
- Cybros-side runtime compatibility
- post-rename bundled identity consistency

Do not add speculative checks unrelated to this host replacement.

**Step 4: Run test to verify it passes**

Run:

- `cd cybros/agents/claw && bin/test`
- `cd cybros && bin/rails test test/integration/agent_runtime_binding_cutover_test.rb test/integration/bundled_default_agent_host_cutover_test.rb`

Expected: PASS for both command groups.

**Step 5: Commit**

```bash
git add cybros/agents/claw/bin/test cybros/bin/ci
git commit -m "test: wire bundled agent host verification"
```
