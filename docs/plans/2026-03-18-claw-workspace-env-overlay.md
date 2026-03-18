# Claw Workspace Env Overlay Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a lane-aware, agent-root-overridable env overlay for bundled `claw` shell execution, protect `.env*` mutations behind approval, and prove the feature in development by fixing the motivating `rbenv` Ruby-path scenario.

**Architecture:** Add a small env overlay loader inside `agents/claw` that merges `agent_root` and current `lane` `.env` / `.env.agent` files into each `exec` subprocess without mutating the long-lived Rails process environment. Carry `lane_path` through the existing workspace payload, extend both `claw` and app-side protected-path policy for `.env*`, and finish with a real live-acceptance flow in development that reproduces and fixes the Ruby path problem.

**Tech Stack:** Ruby, Rails, Minitest, Open3, Pathname, existing `agents/claw` RPC contract tests, existing app-side protected-path policy tests, existing live-acceptance harness patterns.

---

### Task 1: Build A Workspace Env Overlay Loader

**Files:**
- Create: `agents/claw/lib/cybros/agents/claw/workspace_env_overlay.rb`
- Create: `agents/claw/test/unit/workspace_env_overlay_test.rb`
- Modify: `agents/claw/lib/cybros/agents/claw.rb`

**Step 1: Write the failing test**

Add `agents/claw/test/unit/workspace_env_overlay_test.rb` with cases for:

```ruby
test "merges root and lane env files in order" do
  result = WorkspaceEnvOverlay.load(process_env: { "PATH" => "/usr/bin" }, root_path: root, lane_path: lane)
  assert_equal "/lane/bin", result.fetch(:env).fetch("PATH")
end

test "supports unset directives" do
  result = WorkspaceEnvOverlay.load(process_env: { "RUBYOPT" => "-rbundler/setup" }, root_path: root, lane_path: lane)
  refute result.fetch(:env).key?("RUBYOPT")
end

test "ignores malformed files and records warnings" do
  result = WorkspaceEnvOverlay.load(process_env: {}, root_path: root, lane_path: lane)
  assert_equal [lane.join(".env.agent").to_s], result.fetch(:ignored_files)
end
```

**Step 2: Run test to verify it fails**

Run:

```bash
cd agents/claw
bin/test test/unit/workspace_env_overlay_test.rb
```

Expected: FAIL because `WorkspaceEnvOverlay` does not exist yet.

**Step 3: Write minimal implementation**

Implement a small loader object with a single public entrypoint, for example:

```ruby
module Cybros
  module Agents
    module Claw
      class WorkspaceEnvOverlay
        def self.load(process_env:, root_path:, lane_path:)
          # returns merged env plus non-sensitive metadata
        end
      end
    end
  end
end
```

Behavior to implement now:

- read only these files, in this order:
  - `root_path/.env`
  - `root_path/.env.agent`
  - `lane_path/.env`
  - `lane_path/.env.agent`
- support `KEY=VALUE`, `export KEY=VALUE`, `unset KEY`, and `KEY=`
- ignore missing files
- ignore malformed files and collect safe warnings
- return a stable structure containing:
  - `env`
  - `loaded_files`
  - `ignored_files`
  - `warnings`

**Step 4: Run test to verify it passes**

Run:

```bash
cd agents/claw
bin/test test/unit/workspace_env_overlay_test.rb
```

Expected: PASS

**Step 5: Commit**

```bash
git add agents/claw/lib/cybros/agents/claw/workspace_env_overlay.rb agents/claw/lib/cybros/agents/claw.rb agents/claw/test/unit/workspace_env_overlay_test.rb
git commit -m "feat: add claw workspace env overlay loader"
```

### Task 2: Wire The Overlay Into `exec`

**Files:**
- Modify: `agents/claw/lib/cybros/agents/claw/tool_executor.rb`
- Modify: `agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb`
- Modify: `agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Extend `agents/claw/test/integration/rpc_contract_test.rb` with cases for:

```ruby
test "tool.execute exec applies lane env over root env" do
  payload = tool_execute(...)
  result = JSON.parse(payload.dig("result", "content", 0, "text"))
  assert_equal "/lane/ruby", result.fetch("stdout").strip
end

test "tool.execute exec returns env overlay metadata without leaking values" do
  payload = tool_execute(...)
  metadata = payload.dig("result", "metadata")
  assert_equal true, metadata.fetch("env_overlay_applied")
  assert_includes metadata.fetch("env_files_loaded"), lane_env_path
end
```

Use commands such as `printf '%s' "$PATH"` or `printf '%s' "$RBENV_ROOT"` instead of model-dependent output.

**Step 2: Run test to verify it fails**

Run:

```bash
cd agents/claw
bin/test test/integration/rpc_contract_test.rb
```

Expected: FAIL because `WorkspaceTools#exec` does not yet load the overlay, and `ToolExecutor` does not yet carry `lane_path`.

**Step 3: Write minimal implementation**

Implement all of the following together:

- extend `workspace_config_from` in `ToolExecutor` so it returns:
  - `root_path`
  - `cwd`
  - `conversation_path`
  - `lane_path`
- extend `WorkspaceTools.new(...)` to accept `lane_path`
- in `WorkspaceTools#exec`, call `WorkspaceEnvOverlay.load(...)`
- pass `overlay.fetch(:env)` to `Open3.capture3`
- include non-sensitive overlay metadata in the JSON result

Keep the current command execution model:

- still run `"/bin/sh", "-lc", command`
- still use the conversation directory as `chdir`
- do not mutate global `ENV`

**Step 4: Run test to verify it passes**

Run:

```bash
cd agents/claw
bin/test test/unit/workspace_env_overlay_test.rb test/integration/rpc_contract_test.rb
```

Expected: PASS

**Step 5: Commit**

```bash
git add agents/claw/lib/cybros/agents/claw/tool_executor.rb agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: apply env overlay to claw exec"
```

### Task 3: Protect `.env*` In The Runtime And Preserve Snapshots

**Files:**
- Modify: `agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb`
- Modify: `agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Extend `agents/claw/test/integration/rpc_contract_test.rb` with cases for:

```ruby
test "write to current lane env file snapshots prior content" do
  payload = tool_execute(logical_tool_name: "write", ...)
  assert_predicate Pathname.new(history_snapshot_path), :file?
end

test "exec cannot mutate env overlay files through shell redirection" do
  payload = tool_execute(logical_tool_name: "exec", arguments: { "command" => "echo PATH=/tmp > .env.agent" }, ...)
  assert_equal true, payload.dig("result", "error")
end
```

Also cover runtime-side guard behavior:

- `agent_root/.env*` writes snapshot prior content
- `conversation_path/.env*` is denied
- non-current lane `.env*` is denied

**Step 2: Run test to verify it fails**

Run:

```bash
cd agents/claw
bin/test test/integration/rpc_contract_test.rb
```

Expected: FAIL because the current protected-path rules only know about `SOUL.md`, `USER.md`, `AGENTS.md`, and `skills/**`, so `.env*` files are neither snapshot-protected nor denied correctly.

**Step 3: Write minimal implementation**

In `WorkspaceTools`:

- make `protected_path_rule` lane-aware
- treat these paths as `:confirm`:
  - `root/.env`
  - `root/.env.agent`
  - `current_lane/.env`
  - `current_lane/.env.agent`
- treat these paths as `:deny`:
  - `conversation/.env*`
  - any non-current lane `.env*`
  - `.history/**`
  - `AGENTS.md`
- let `snapshot_protected_path!` include protected `.env*` files automatically
- keep `protected_exec_error_for` aligned with the same path rules

**Step 4: Run test to verify it passes**

Run:

```bash
cd agents/claw
bin/test test/integration/rpc_contract_test.rb
```

Expected: PASS

**Step 5: Commit**

```bash
git add agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: protect claw env overlay files"
```

### Task 4: Mirror The Env Rules In App-Side Policy

**Files:**
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_test.rb`

**Step 1: Write the failing test**

Extend `cybros/test/lib/cybros/agent_runtime_resolver_test.rb` with cases for:

```ruby
test "protected path classifier confirms writes to current lane env files" do
  result = classifier.call(name: "write", arguments: { "path" => ".lanes/lane:test-default/.env.agent" }, context: context)
  assert_equal :confirm, result.fetch(:action)
end

test "protected path classifier denies conversation env shadow files" do
  result = classifier.call(name: "write", arguments: { "path" => ".env.agent" }, context: context)
  assert_equal :deny, result.fetch(:action)
end
```

Add companion `exec` redirection cases so the app policy blocks shell-based mutation before RPC dispatch.

**Step 2: Run test to verify it fails**

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/agent_runtime_resolver_test.rb
```

Expected: FAIL because the classifier does not yet know `.env*`, `lane_path`, or conversation-scope env shadow paths.

**Step 3: Write minimal implementation**

Update `ProtectedAgentPathClassifier` so it:

- reads `lane_path` from the execution context workspace payload
- classifies current-lane and agent-root `.env*` as confirmable
- classifies conversation-scope `.env*` and non-current-lane `.env*` as denied
- applies the same logic to direct file mutations and `exec`-based redirection attempts

Keep all existing `SOUL.md`, `USER.md`, `skills/**`, `.history/**`, and `AGENTS.md` behavior intact.

**Step 4: Run test to verify it passes**

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/agent_runtime_resolver_test.rb
```

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/cybros/agent_runtime_resolver.rb cybros/test/lib/cybros/agent_runtime_resolver_test.rb
git commit -m "feat: add env overlay policy guards"
```

### Task 5: Add Real Development Acceptance For The `rbenv` Scenario

**Files:**
- Create: `cybros/script/live_acceptance/claw_workspace_env_overlay.rb`
- Create: `cybros/test/script/live_acceptance/claw_workspace_env_overlay_test.rb`

**Step 1: Write the failing test**

Create `cybros/test/script/live_acceptance/claw_workspace_env_overlay_test.rb` covering a focused live-acceptance runner contract:

```ruby
test "runner defines the ruby-path env scenario and a report path" do
  assert_equal "claw_workspace_env_overlay", runner.report_slug
end

test "runner can build lane and root env files for the rbenv scenario" do
  payload = runner.send(:scenario_payload_for, ...)
  assert_includes payload.fetch(:lane_env_body), "RBENV_ROOT="
end
```

Keep the test narrow: verify harness shape, scenario IDs, report generation, and non-live helper behavior.

**Step 2: Run test to verify it fails**

Run:

```bash
cd cybros
bin/rails test test/script/live_acceptance/claw_workspace_env_overlay_test.rb
```

Expected: FAIL because the live-acceptance runner does not exist yet.

**Step 3: Write minimal implementation**

Create a focused runner that:

- resolves a live model ref from the configured providers
- provisions a lane-local `.env.agent` with the motivating Ruby-path fixes
- submits a real development conversation asking the agent to inspect `which ruby` and `ruby -v`
- verifies the lane-local fix works
- promotes the stable config into `agent_root/.env.agent`
- starts a fresh lane and verifies the shared root config works there too
- writes a proof report under `cybros/docs/reports/`

Prefer reusing helper patterns from `script/live_acceptance/agent_root_workspace.rb` rather than editing that larger harness.

**Step 4: Run test to verify it passes**

Run:

```bash
cd cybros
bin/rails test test/script/live_acceptance/claw_workspace_env_overlay_test.rb
```

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/script/live_acceptance/claw_workspace_env_overlay.rb cybros/test/script/live_acceptance/claw_workspace_env_overlay_test.rb
git commit -m "test: add claw env overlay live acceptance harness"
```

## Verification And Acceptance

After the five tasks land, run the full verification set in this order:

```bash
cd agents/claw
bin/test test/unit/workspace_env_overlay_test.rb test/integration/rpc_contract_test.rb

cd /Users/jasl/Workspaces/Cybros/cybros/cybros
bin/rails test test/lib/cybros/agent_runtime_resolver_test.rb test/script/live_acceptance/claw_workspace_env_overlay_test.rb
```

Then run the real development proof:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros
bin/rails runner script/live_acceptance/claw_workspace_env_overlay.rb
```

Development acceptance is only complete if all of the following are true:

- automated tests pass
- the live-acceptance run uses a real configured model in development
- the lane-local `.env.agent` fixes the motivating Ruby path issue
- promoting the config to `agent_root/.env.agent` makes a fresh lane inherit the fix
- the proof report is written and names the concrete Ruby executable or version that was observed
