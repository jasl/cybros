# Bundled Agent Rails Host Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep `cybros/agents/default` as the known-good baseline, merge its effective runtime logic into `cybros/vendor/agents/claw`, prove side-by-side parity, then cut over so `cybros/agents/claw` becomes the canonical bundled agent implementation and `default` is deleted.

**Architecture:** Build the new Rails/Puma implementation in `cybros/vendor/agents/claw` first. Reuse the current manifest, identity, dispatcher, hooks, prompts, and contract tests from `cybros/agents/default` wherever possible. Only after parity is proven should the bundled source root and bundled identity switch from `default` to `claw`.

**Tech Stack:** Ruby, Rails API-only app, Puma, JSON-RPC over HTTP, Minitest, Net::HTTP, current bundled-agent runtime objects, Cybros programmable-agent bootstrap/runtime services

---

### Task 1: Freeze The Current `default` Contract

**Files:**
- Modify: `cybros/agents/default/test/integration/rpc_contract_test.rb`
- Modify: `cybros/agents/default/test/unit/manifest_test.rb`
- Modify: `cybros/agents/default/test/test_helper.rb`
- Create: `cybros/agents/default/test/support/contract_assertions.rb`

**Step 1: Write the failing test**

Add contract coverage for:

- `POST /rpc` and `GET /health`
- auth failure behavior
- malformed JSON behavior
- unsupported method behavior
- all shipped hook methods and attachment import shape

Extract reusable assertions so the same external-contract expectations can later be run against `claw`.

**Step 2: Run test to verify it fails**

Run: `cd cybros/agents/default && bin/test`

Expected: FAIL because the current tests are not yet fully expressing the reusable external contract.

**Step 3: Write minimal implementation**

Only improve the `default` test suite and helpers.
Do not change runtime behavior yet.

**Step 4: Run test to verify it passes**

Run: `cd cybros/agents/default && bin/test`

Expected: PASS with `default` still acting as the baseline implementation.

**Step 5: Commit**

```bash
git add cybros/agents/default/test/integration/rpc_contract_test.rb cybros/agents/default/test/unit/manifest_test.rb cybros/agents/default/test/test_helper.rb cybros/agents/default/test/support/contract_assertions.rb
git commit -m "test: freeze bundled default agent contract"
```

### Task 2: Complete The Rails Host Skeleton In `vendor/agents/claw`

**Files:**
- Modify: `cybros/vendor/agents/claw/Gemfile`
- Modify: `cybros/vendor/agents/claw/Gemfile.lock`
- Modify: `cybros/vendor/agents/claw/Rakefile`
- Modify: `cybros/vendor/agents/claw/config/routes.rb`
- Modify: `cybros/vendor/agents/claw/config/application.rb`
- Modify: `cybros/vendor/agents/claw/config/puma.rb`
- Modify: `cybros/vendor/agents/claw/config.ru`
- Modify: `cybros/vendor/agents/claw/bin/server`
- Modify: `cybros/vendor/agents/claw/bin/test`
- Modify: `cybros/vendor/agents/claw/test/test_helper.rb`
- Create: `cybros/vendor/agents/claw/app/controllers/health_controller.rb`
- Create: `cybros/vendor/agents/claw/app/controllers/rpc_controller.rb`
- Create: `cybros/vendor/agents/claw/app/controllers/concerns/json_rpc_error_renderer.rb`
- Create: `cybros/vendor/agents/claw/test/requests/http_boundary_test.rb`

**Step 1: Write the failing test**

Add Rails request tests that expect:

- `POST /rpc`
- `GET /health`
- JSON request parsing
- bearer authentication
- JSON-RPC shaped responses

**Step 2: Run test to verify it fails**

Run: `cd cybros/vendor/agents/claw && bundle exec rails test test/requests/http_boundary_test.rb`

Expected: FAIL because the skeleton does not yet expose the bundled-agent HTTP boundary.

**Step 3: Write minimal implementation**

Make `claw` a usable API-only Rails host:

- add thin `/rpc` and `/health` routes/controllers
- wire Puma/server/test boot
- add request-level error rendering

Do not port bundled-agent business logic yet.

**Step 4: Run test to verify it passes**

Run: `cd cybros/vendor/agents/claw && bundle exec rails test test/requests/http_boundary_test.rb`

Expected: PASS with the Rails host boundary working.

**Step 5: Commit**

```bash
git add cybros/vendor/agents/claw/Gemfile cybros/vendor/agents/claw/Gemfile.lock cybros/vendor/agents/claw/Rakefile cybros/vendor/agents/claw/config/routes.rb cybros/vendor/agents/claw/config/application.rb cybros/vendor/agents/claw/config/puma.rb cybros/vendor/agents/claw/config.ru cybros/vendor/agents/claw/bin/server cybros/vendor/agents/claw/bin/test cybros/vendor/agents/claw/test/test_helper.rb cybros/vendor/agents/claw/app/controllers/health_controller.rb cybros/vendor/agents/claw/app/controllers/rpc_controller.rb cybros/vendor/agents/claw/app/controllers/concerns/json_rpc_error_renderer.rb cybros/vendor/agents/claw/test/requests/http_boundary_test.rb
git commit -m "feat: complete claw rails host boundary"
```

### Task 3: Merge The Effective `default` Runtime Logic Into `claw`

**Files:**
- Create: `cybros/vendor/agents/claw/agent.yml`
- Create: `cybros/vendor/agents/claw/prompts/AGENT.md`
- Create: `cybros/vendor/agents/claw/prompts/SOUL.md`
- Create: `cybros/vendor/agents/claw/prompts/USER.md`
- Create: `cybros/vendor/agents/claw/prompts/system.md.liquid`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/application.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/manifest.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/identity.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/rpc_dispatcher.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/hooks/on_conversation_created.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/hooks/on_lane_first_user_message.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/hooks/before_subagent_spawn.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/hooks/before_finalize_output.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/hooks/after_task_notice.rb`
- Create: `cybros/vendor/agents/claw/lib/cybros/agents/claw/hooks/after_subagent_result.rb`
- Create: `cybros/vendor/agents/claw/test/unit/manifest_test.rb`
- Create: `cybros/vendor/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Port or mirror the relevant `default` unit/integration tests so `claw` must satisfy:

- manifest loading
- identity payload
- RPC method dispatch
- hook behavior
- attachment import behavior

**Step 2: Run test to verify it fails**

Run: `cd cybros/vendor/agents/claw && bin/test`

Expected: FAIL because `claw` does not yet contain the bundled-agent runtime core.

**Step 3: Write minimal implementation**

Merge the effective logic from `cybros/agents/default` into `claw`:

- manifest
- identity
- dispatcher
- hooks
- prompt assets
- attachment import behavior

Keep `claw` Rails-hosted, but keep the runtime core mostly pure Ruby.

**Step 4: Run test to verify it passes**

Run: `cd cybros/vendor/agents/claw && bin/test`

Expected: PASS with `claw` implementing the same effective behavior as `default`, aside from deliberate temporary naming differences.

**Step 5: Commit**

```bash
git add cybros/vendor/agents/claw/agent.yml cybros/vendor/agents/claw/prompts cybros/vendor/agents/claw/lib/cybros/agents/claw.rb cybros/vendor/agents/claw/lib/cybros/agents/claw cybros/vendor/agents/claw/test/unit/manifest_test.rb cybros/vendor/agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: merge bundled agent runtime into claw"
```

### Task 4: Prove Side-By-Side Parity Between `default` And `claw`

**Files:**
- Create: `cybros/test/integration/bundled_agent_parity_test.rb`
- Modify: `cybros/agents/default/test/support/contract_assertions.rb`
- Modify: `cybros/vendor/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Add parity coverage that boots both implementations and compares:

- method surface
- health/identity compatibility
- hook result shapes
- attachment import shape
- JSON-RPC error semantics

Allow only the explicitly planned naming differences needed before the final identity cut.

**Step 2: Run test to verify it fails**

Run: `cd cybros && bin/rails test test/integration/bundled_agent_parity_test.rb`

Expected: FAIL because `claw` and `default` have not yet reached provable parity.

**Step 3: Write minimal implementation**

Adjust only `claw` until parity holds.
Do not cut product bootstrap over yet.

**Step 4: Run test to verify it passes**

Run: `cd cybros && bin/rails test test/integration/bundled_agent_parity_test.rb`

Expected: PASS with `default` and `claw` externally aligned.

**Step 5: Commit**

```bash
git add cybros/test/integration/bundled_agent_parity_test.rb cybros/agents/default/test/support/contract_assertions.rb cybros/vendor/agents/claw/test/integration/rpc_contract_test.rb
git commit -m "test: prove bundled agent parity between default and claw"
```

### Task 5: Cut Over Bundled Bootstrap And Source Resolution To `claw`

**Files:**
- Move: `cybros/vendor/agents/claw` -> `cybros/agents/claw`
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

**Step 1: Write the failing test**

Add or update Cybros-side tests so they expect:

- bundled source resolution points to `agents/claw`
- bootstrap provisions bundled identity `claw`
- dashboard/setup flows use `claw`
- bundled implementation special-cases no longer hard-code `default`

**Step 2: Run test to verify it fails**

Run: `cd cybros && bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb test/integration/agent_runtime_binding_cutover_test.rb test/integration/setup_and_sessions_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/bundled_default_agent_execution_test.rb test/integration/programmable_agent_capabilities_handshake_test.rb`

Expected: FAIL because product bootstrap and source resolution still point at `default`.

**Step 3: Write minimal implementation**

Perform the real cutover:

- move canonical source root to `cybros/agents/claw`
- switch bundled identity from `default` to `claw`
- update manifest/config namespace/fingerprints/user-facing text
- update product/runtime special-casing
- keep protocol shape unchanged

**Step 4: Run test to verify it passes**

Run: `cd cybros && bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb test/integration/agent_runtime_binding_cutover_test.rb test/integration/setup_and_sessions_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/bundled_default_agent_execution_test.rb test/integration/programmable_agent_capabilities_handshake_test.rb`

Expected: PASS with `claw` now acting as the bundled implementation.

**Step 5: Commit**

```bash
git add cybros/agents/claw cybros/app/services/agents/bundled_sources.rb cybros/app/services/agents/bootstrap_bundled_default_service.rb cybros/app/services/conversations/attachment_transfer_service.rb cybros/app/models/agent.rb cybros/app/controllers/dashboard_controller.rb cybros/test/services/agents/bootstrap_bundled_default_service_test.rb cybros/test/integration/agent_runtime_binding_cutover_test.rb cybros/test/integration/setup_and_sessions_test.rb cybros/test/integration/default_agent_attachment_transfer_test.rb cybros/test/integration/bundled_default_agent_execution_test.rb cybros/test/integration/programmable_agent_capabilities_handshake_test.rb
git rm -r cybros/vendor/agents/claw
git commit -m "refactor: cut bundled agent over to claw"
```

### Task 6: Delete The Legacy `default` Implementation

**Files:**
- Delete: `cybros/agents/default`
- Modify: `cybros/docs/product/agent_rpc.md`
- Modify: `cybros/docs/plans/2026-03-14-bundled-default-rails-agent-host-design.md`
- Modify: `cybros/test/integration/bundled_agent_parity_test.rb`

**Step 1: Write the failing test**

Add cleanup assertions proving:

- no bundled source registry points at `default`
- no runtime bootstrap depends on `agents/default`
- docs/tests no longer describe `default` as the active bundled implementation

**Step 2: Run test to verify it fails**

Run: `cd cybros && bin/rails test test/integration/bundled_agent_parity_test.rb test/integration/agent_runtime_binding_cutover_test.rb`

Expected: FAIL because the legacy source tree and related references still exist.

**Step 3: Write minimal implementation**

Delete the old tree and update docs/tests that still treat it as active.

**Step 4: Run test to verify it passes**

Run: `cd cybros && bin/rails test test/integration/bundled_agent_parity_test.rb test/integration/agent_runtime_binding_cutover_test.rb`

Expected: PASS with `default` fully retired.

**Step 5: Commit**

```bash
git add cybros/docs/product/agent_rpc.md cybros/docs/plans/2026-03-14-bundled-default-rails-agent-host-design.md cybros/test/integration/bundled_agent_parity_test.rb cybros/test/integration/agent_runtime_binding_cutover_test.rb
git rm -r cybros/agents/default
git commit -m "refactor: remove legacy bundled default implementation"
```

### Task 7: Run Final Verification Before Merge

**Files:**
- Modify: `cybros/agents/claw/bin/test`
- Modify: `cybros/bin/ci`

**Step 1: Write the failing test**

Make the verification entrypoints prove:

- agent-side tests run from `cybros/agents/claw`
- Cybros-side bundled runtime tests pass against `claw`

**Step 2: Run test to verify it fails**

Run: `cd cybros/agents/claw && bin/test`

Expected: FAIL if any cutover or cleanup drift remains.

**Step 3: Write minimal implementation**

Wire the final verification commands into the normal developer workflow.

**Step 4: Run test to verify it passes**

Run:

- `cd cybros/agents/claw && bin/test`
- `cd cybros && bin/rails test test/integration/bundled_agent_parity_test.rb test/integration/agent_runtime_binding_cutover_test.rb test/services/agents/bootstrap_bundled_default_service_test.rb`

Expected: PASS for both command groups.

**Step 5: Commit**

```bash
git add cybros/agents/claw/bin/test cybros/bin/ci
git commit -m "test: wire claw bundled agent verification"
```
