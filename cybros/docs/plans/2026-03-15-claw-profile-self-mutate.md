# Claw Profile Self-Mutate Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add bundled `claw` self-mutate support for per-user `SOUL.md` and `USER.md` overrides through staged diffs plus explicit confirmation before apply.

**Architecture:** Bundled `claw` keeps user-scoped profile files under an agent-owned storage root outside the app repository. The agent surface exposes `profile_get`, `profile_stage_update`, and `profile_apply_update` through `tool.execute`, while Cybros prompt assembly prefers user overrides over bundled defaults. `profile_apply_update` is always forced through Cybros tool confirmation, even under `full_access`.

**Tech Stack:** Ruby, Rails, programmable agent RPC, AgentCore tool policy, Minitest, file-backed agent-owned state

---

### Task 1: Add A User-Scoped Claw Profile Store

**Files:**
- Create: `cybros/agents/claw/lib/cybros/agents/claw/profile_store.rb`
- Create: `cybros/agents/claw/test/unit/profile_store_test.rb`

**Step 1: Write the failing test**

Add unit tests for:

- user-scoped storage root resolution under the instance agent workspace root
- target validation for `soul|user`
- reading an override document
- revision calculation from document body

```ruby
test "profile store resolves user-scoped soul file under the claw agent-owned root" do
  store = Cybros::Agents::Claw::ProfileStore.new(user_id: "user-123", workspace_root: tmp_root)

  assert_equal tmp_root.join("agent-owned/claw/users/user-123/SOUL.md"), store.send(:live_path_for, "soul")
end

test "profile store rejects unsupported targets" do
  store = Cybros::Agents::Claw::ProfileStore.new(user_id: "user-123", workspace_root: tmp_root)

  error = assert_raises(Cybros::Agents::Claw::ProfileStore::Error) { store.get(target: "identity") }
  assert_equal "claw.profile.target_invalid", error.code
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/unit/profile_store_test.rb`

Expected: FAIL because `ProfileStore` does not exist yet.

**Step 3: Write minimal implementation**

Create `ProfileStore` with:

- `target = soul|user`
- root path:

```ruby
Pathname.new(workspace_root).join("agent-owned", "claw", "users", user_id.to_s)
```

- live paths:

```ruby
{
  "soul" => root.join("SOUL.md"),
  "user" => root.join("USER.md"),
}
```

- `revision_for(body)` based on `Digest::SHA256.hexdigest(body.to_s)`

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/unit/profile_store_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/profile_store.rb cybros/agents/claw/test/unit/profile_store_test.rb
git commit -m "feat: add claw profile store"
```

### Task 2: Add Staged Proposal And Apply Semantics To The Profile Store

**Files:**
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/profile_store.rb`
- Modify: `cybros/agents/claw/test/unit/profile_store_test.rb`

**Step 1: Write the failing test**

Add unit tests for:

- `stage_update` writing `.staged/<proposal_id>.json`
- `apply_update` moving the old live file into `.history/`
- `apply_update` rejecting revision conflicts
- staged proposal status transitions (`staged` -> `applied`)

```ruby
test "apply_update archives the previous soul file and writes the staged body" do
  store = build_store_with_live_file(target: "soul", body: "old soul")
  proposal = store.stage_update(target: "soul", body: "new soul", base_revision: store.get(target: "soul").fetch("revision"))

  result = store.apply_update(proposal_id: proposal.fetch("proposal_id"))

  assert_equal "new soul", File.read(store.send(:live_path_for, "soul"))
  assert_equal "applied", result.fetch("status")
  assert_predicate store.send(:history_dir), :directory?
end

test "apply_update rejects stale staged proposals" do
  store = build_store_with_live_file(target: "user", body: "old user")
  current = store.get(target: "user")
  proposal = store.stage_update(target: "user", body: "new user", base_revision: current.fetch("revision"))
  File.write(store.send(:live_path_for, "user"), "changed elsewhere")

  error = assert_raises(Cybros::Agents::Claw::ProfileStore::Error) { store.apply_update(proposal_id: proposal.fetch("proposal_id")) }
  assert_equal "claw.profile.revision_conflict", error.code
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/unit/profile_store_test.rb`

Expected: FAIL because staging and apply behavior are not implemented.

**Step 3: Write minimal implementation**

Implement:

- `stage_update(target:, body:, base_revision:, summary: nil)`
- `apply_update(proposal_id:)`
- proposal JSON shape:

```json
{
  "proposal_id": "uuid",
  "target": "soul",
  "status": "staged",
  "base_revision": "sha256...",
  "body": "new content",
  "created_at": "2026-03-15T12:00:00Z"
}
```

- history archive names:

```ruby
"#{Time.current.utc.strftime("%Y%m%d%H%M%S")}-SOUL.md"
```

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/unit/profile_store_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/profile_store.rb cybros/agents/claw/test/unit/profile_store_test.rb
git commit -m "feat: add claw profile staging and apply flow"
```

### Task 3: Advertise Profile Self-Mutate Tools In Both Tool Surfaces

**Files:**
- Modify: `cybros/lib/cybros/agent_owned_tools.rb`
- Modify: `cybros/agents/claw/agent.yml`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/application.rb`
- Modify: `cybros/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Add contract assertions that:

- handshake/refresh include `profile_get`
- handshake/refresh include `profile_stage_update`
- handshake/refresh include `profile_apply_update`

Also add tool schema visibility assertions for the Cybros-side registry:

```ruby
test "agent-owned tools include profile self-mutate schemas" do
  names = Cybros::AgentOwnedTools.build.map(&:name)

  assert_includes names, "profile_get"
  assert_includes names, "profile_stage_update"
  assert_includes names, "profile_apply_update"
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because the catalog and schema registry do not include the new tools.

**Step 3: Write minimal implementation**

Add three new agent-owned tool definitions:

```ruby
tool(name: "profile_get", permission_class: "read", ...)
tool(name: "profile_stage_update", permission_class: "mutate", ...)
tool(name: "profile_apply_update", permission_class: "mutate", ...)
```

Add matching entries to bundled `claw` catalog:

```ruby
{ "logical_tool_name" => "profile_get", "implementation_ref" => "claw:profile_get", "execution_mode" => "serial" }
```

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/cybros/agent_owned_tools.rb cybros/agents/claw/agent.yml cybros/agents/claw/lib/cybros/agents/claw/application.rb cybros/agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: advertise claw profile self-mutate tools"
```

### Task 4: Implement `profile_get` And `profile_stage_update` Through `tool.execute`

**Files:**
- Create: `cybros/agents/claw/lib/cybros/agents/claw/tools/profile_tools.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb`
- Modify: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Modify: `cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`

**Step 1: Write the failing test**

Add RPC contract tests for:

- `profile_get` returning bundled/default metadata when no override exists
- `profile_stage_update` returning `proposal_id` and diff preview

Add a DAG scenario test that shows staged proposal output is transcript-visible.

```ruby
payload =
  tool_execute(
    logical_tool_name: "profile_stage_update",
    implementation_ref: "claw:profile_stage_update",
    arguments: {
      "target" => "soul",
      "body" => "New soul",
      "base_revision" => current_revision,
    },
    user_id: conversation.user_id,
  )

assert_equal false, payload.fetch("result").fetch("error")
assert_includes JSON.parse(payload.dig("result", "content", 0, "text")).keys, "proposal_id"
```

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because `ProfileTools` do not exist.

**Step 3: Write minimal implementation**

Create `ProfileTools` that:

- reads `user_id` from `session_context` / `execution_context`
- instantiates `ProfileStore`
- handles:

```ruby
when "profile_get"
  store.get(target: arguments.fetch("target"))
when "profile_stage_update"
  store.stage_update(
    target: arguments.fetch("target"),
    body: arguments.fetch("body"),
    base_revision: arguments.fetch("base_revision"),
    summary: arguments["summary"],
  )
```

Wire `ToolExecutor` to call `ProfileTools` before returning “not implemented”.

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/tools/profile_tools.rb cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb cybros/agents/claw/test/integration/rpc_contract_test.rb cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb
git commit -m "feat: add claw profile get and stage tools"
```

### Task 5: Force `profile_apply_update` Through Tool Confirmation

**Files:**
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`
- Modify: `cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tools/profile_tools.rb`
- Modify: `cybros/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Add tests that:

- `runtime.tool_policy.authorize(name: "profile_apply_update", ...)` returns `:confirm` even under `full_access`
- a DAG flow calling `profile_apply_update` lands in `awaiting_approval`

```ruby
test "profile_apply_update always requires confirmation" do
  runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node, ...)
  ctx = AgentCore::ExecutionContext.new(instrumenter: AgentCore::Observability::NullInstrumenter.new)

  decision = runtime.tool_policy.authorize(name: "profile_apply_update", arguments: { "proposal_id" => "p1" }, context: ctx)
  assert_equal :confirm, decision.outcome
end
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

Expected: FAIL because `profile_apply_update` is currently treated like any other mutate tool.

**Step 3: Write minimal implementation**

Wrap the existing tool policy with an explicit confirm rule:

```ruby
AgentCore::Resources::Tools::Policy::Ruleset.new(
  confirm: [
    { tools: ["profile_apply_update"], reason: "claw_profile_apply_requires_confirmation", required: true, deny_effect: "block" },
  ],
  delegate: existing_policy,
)
```

Then implement `profile_apply_update` in `ProfileTools` by calling `ProfileStore#apply_update`.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/cybros/agent_runtime_resolver.rb cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb cybros/agents/claw/lib/cybros/agents/claw/tools/profile_tools.rb cybros/agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: require confirmation for claw profile apply"
```

### Task 6: Resolve `SOUL` / `USER` Overrides During Prompt Assembly

**Files:**
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`
- Modify: `cybros/test/integration/programmable_agent_prompt_builder_test.rb`
- Modify: `cybros/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Add prompt-builder coverage for:

- primary runs use user-scoped `SOUL` override when present
- primary runs use user-scoped `USER` override when present
- subagent/minimal prompt still excludes both

```ruby
assert_includes system_prompt, "override soul line"
refute_includes system_prompt, "bundled soul line"
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/programmable_agent_prompt_builder_test.rb`

Expected: FAIL because bootstrap sources still read bundled prompt files directly.

**Step 3: Write minimal implementation**

Replace direct reads with profile-aware resolution:

```ruby
def resolved_profile_prompt_text(target:, params:)
  store = profile_store_for(params)
  override = store&.override_body_for(target: target)
  return override if override.present?

  @application.prompt_text(target)
end
```

Keep minimal/subagent behavior unchanged.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/programmable_agent_prompt_builder_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb cybros/test/integration/programmable_agent_prompt_builder_test.rb cybros/agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: resolve claw soul and user overrides in prompt assembly"
```

### Task 7: Add Final Acceptance Coverage And Proof Notes

**Files:**
- Modify: `cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`
- Create: `cybros/docs/reports/2026-03-15-claw-profile-self-mutate-proof.md`

**Step 1: Write the failing test**

Add an end-to-end DAG scenario:

- get current profile
- stage update
- enter awaiting approval on apply
- approve
- verify next turn reads the updated `SOUL` / `USER`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: FAIL until prompt re-read and approval/apply flow are wired end-to-end.

**Step 3: Write minimal implementation**

Complete any missing glue discovered by the scenario and write a proof report with:

- exact conversation/lane ids
- tool activity sequence
- confirmation that `IDENTITY` / `HEARTBEAT` remain out of scope

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb cybros/docs/reports/2026-03-15-claw-profile-self-mutate-proof.md
git commit -m "test: prove claw profile self-mutate flow"
```

## Verification Bundle

Do not call this feature complete until all of these pass:

- `bundle exec ruby -Itest cybros/agents/claw/test/unit/profile_store_test.rb`
- `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`
- `bin/rails test test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`
- `bin/rails test test/integration/programmable_agent_prompt_builder_test.rb`
- `bin/rails test test/scenarios/dag/agent_tool_calls_flow_test.rb`

Plan complete and saved to `docs/plans/2026-03-15-claw-profile-self-mutate.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
