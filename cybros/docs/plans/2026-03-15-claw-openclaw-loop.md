# Claw OpenClaw Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Teach the bundled `claw` agent to run an OpenClaw-style default loop by adding agent-owned coding tools first, then conversation-owned memory and assistant tools on the same execution spine, while keeping agent loop control, subagent execution, and final output authority inside the Cybros DAG engine.

**Architecture:** Cybros continues to own DAG orchestration, tool-task routing, subagent conversations, approvals, transcript state, and capability snapshots. The bundled `claw` host becomes an agent-owned tool provider through `agent_tool_catalog + tool.execute`, while `MEMORY` is introduced as a conversation-owned logical document behind a narrow callback API instead of a workspace file source of truth.

**No Shadow Loop Rule:** `claw` may own tools and prompt assembly, but it may not emulate its own scheduler, transcript, subagent runner, or silent-finalization path. If an OpenClaw-like behavior needs a DAG/runtime capability that Cybros does not yet expose, this phase must add that capability to Cybros instead of simulating it inside `claw`.

**Tech Stack:** Ruby on Rails, programmable agent RPC, AgentCore DAG executors, Minitest, YAML manifest config

## Execution Rules

- Write the failing test first for every task.
- Do not continue to the next milestone until the listed verification commands pass.
- Use Cybros-authored runtime signals for prompt mode and delegated execution, specifically `execution_context.execution_scope`, subagent metadata, and the resolved `agent_profile`.
- For mutating memory callbacks, use the normal callback mutation receipt path and require `operation_id`.
- For `web_search`, choose or wire one backend that is runnable in development before final proof. If no backend can be made available, stop at that point and report a blocker instead of continuing with a partial proof.

## Milestones

- **Milestone 1 (`B1`)**: agent-owned coding loop on top of the Cybros DAG spine
  - Tasks 1-5
- **Milestone 2 (`A1`)**: conversation-owned memory on a narrow callback spine
  - Tasks 6-8
- **Milestone 3 (`A2`)**: prompt/bootstrap parity and assistant web tools
  - Tasks 9-11
- **Milestone 4**: Cybros DAG/runtime parity gaps for silent finalization and compaction housekeeping
  - Task 12
- **Milestone 5**: OpenClaw reference audit and real-environment proof
  - Tasks 13-14

---

### Task 1: Advertise Agent-Owned Tool Execution In The Bundled Claw Contract

**Files:**
- Modify: `cybros/agents/claw/agent.yml`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/application.rb`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Test: `cybros/agents/claw/test/support/contract_assertions.rb`

**Step 1: Write the failing test**

Add assertions that:

- `supported_methods` includes `tool.execute`
- handshake/refresh return a non-empty `agent_tool_catalog`

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because `tool.execute` is absent and `agent_tool_catalog` is `[]`.

**Step 3: Write minimal implementation**

- Add `tool.execute` to `cybros/agents/claw/agent.yml`
- Replace `agent_tool_catalog` in `cybros/agents/claw/lib/cybros/agents/claw/application.rb` with a catalog builder method

Start with the smallest catalog for `B1`:

```ruby
[
  { logical_tool_name: "read", implementation_ref: "claw:read", execution_mode: "serial" },
  { logical_tool_name: "write", implementation_ref: "claw:write", execution_mode: "serial" },
  { logical_tool_name: "edit", implementation_ref: "claw:edit", execution_mode: "serial" },
  { logical_tool_name: "apply_patch", implementation_ref: "claw:apply_patch", execution_mode: "serial" },
  { logical_tool_name: "glob", implementation_ref: "claw:glob", execution_mode: "serial" },
  { logical_tool_name: "search", implementation_ref: "claw:search", execution_mode: "serial" },
  { logical_tool_name: "exec", implementation_ref: "claw:exec", execution_mode: "serial" },
]
```

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/agent.yml cybros/agents/claw/lib/cybros/agents/claw/application.rb cybros/agents/claw/test/integration/rpc_contract_test.rb cybros/agents/claw/test/support/contract_assertions.rb
git commit -m "feat: advertise claw agent-owned tools"
```

### Task 2: Route `tool.execute` Requests Inside The Bundled Claw Host

**Files:**
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/rpc_dispatcher.rb`
- Create: `cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Add a direct RPC contract test that calls `tool.execute` for a trivial safe tool like `glob` or `search` and expects a top-level RPC payload containing `"result"`.

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL with unsupported bundled claw RPC method or missing top-level `result`.

**Step 3: Write minimal implementation**

- Add `when "tool.execute"` handling in the dispatcher
- Create `ToolExecutor` with:
  - implementation-ref lookup
  - argument normalization
  - exact response shape: `{ "result" => ToolResult#to_h }`
  - error results also wrapped at the same top-level `result` key

Start with a skeleton dispatcher:

```ruby
when "tool.execute"
  ToolExecutor.new(application: @application).call(params: normalized_params)
```

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/rpc_dispatcher.rb cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb cybros/agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: route tool execution through bundled claw"
```

### Task 3: Build The Conversation Workspace Inspection And Basic File Tools

**Files:**
- Create: `cybros/agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Test: `cybros/test/integration/agent_runtime_binding_cutover_test.rb`

**Step 1: Write the failing test**

Add tests for:

- `glob` returning workspace-relative matches
- `search` returning `path`, `line`, `snippet`
- `read` returning file content
- `write` updating a file in the conversation workspace

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because tool implementations do not exist.

**Step 3: Write minimal implementation**

Use the conversation workspace root from execution/session context and keep all path resolution inside it.

Return JSON text inside the tool result for search-like tools:

```json
{
  "matches": [
    { "path": "app/models/user.rb", "line": 12, "snippet": "class User < ApplicationRecord" }
  ],
  "truncated": false
}
```

For file mutation tools, start with:

- strict realpath containment
- no path traversal
- UTF-8 text only

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb cybros/agents/claw/test/integration/rpc_contract_test.rb cybros/test/integration/agent_runtime_binding_cutover_test.rb
git commit -m "feat: add claw workspace inspection and basic file tools"
```

### Task 4: Add Structured Editing Tools For `edit` And `apply_patch`

**Files:**
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Test: `cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`

**Step 1: Write the failing test**

Add tests for:

- `edit` replacing exact text in a single file and failing on ambiguous matches
- `apply_patch` applying a multi-line patch atomically inside the conversation workspace
- both tools producing DAG-visible tool output

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because `edit` and `apply_patch` are still only declared in the catalog.

**Step 3: Write minimal implementation**

Start with these constraints:

- `edit` works on one file with explicit old/new content boundaries
- `apply_patch` rejects patches that escape the workspace root
- failed hunks do not partially modify files
- successful responses include enough structured detail for the agent to explain what changed

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb cybros/agents/claw/test/integration/rpc_contract_test.rb cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb
git commit -m "feat: add claw edit and apply_patch tools"
```

### Task 5: Add Safe Command Execution For The Coding Loop

**Files:**
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Test: `cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`

**Step 1: Write the failing test**

Add a test for `exec` that:

- runs in the conversation workspace
- returns exit status, stdout, stderr
- preserves DAG-visible tool output

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because `exec` is not implemented.

**Step 3: Write minimal implementation**

Start with non-interactive command execution only.

Return structured output:

```json
{
  "status": "ok",
  "exit_code": 0,
  "stdout": "test output\n",
  "stderr": ""
}
```

Reject empty commands and keep execution rooted in the conversation workspace.

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/tools/workspace_tools.rb cybros/agents/claw/test/integration/rpc_contract_test.rb cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb
git commit -m "feat: add claw workspace exec tool"
```

### Task 6: Widen `tool.execute` To Support Narrow Memory Callback Sessions

**Files:**
- Modify: `cybros/lib/cybros/programmable_agent/tool_execution.rb`
- Test: `cybros/test/services/agent_rpc/lifecycle_caller_test.rb`
- Test: `cybros/agents/claw/test/support/callback_harness.rb`

**Step 1: Write the failing test**

Add tests proving that:

- `tool.execute` can receive `callback_session`
- only `conversation.memory.get/put/append` are allowed
- unrelated callback methods still fail authorization

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/test/services/agent_rpc/lifecycle_caller_test.rb`

Expected: FAIL because `tool.execute` currently opens sessions with `allowed_callback_methods: []`.

**Step 3: Write minimal implementation**

- Add a constant like:

```ruby
TOOL_EXECUTE_CALLBACK_METHODS = %w[
  conversation.memory.get
  conversation.memory.put
  conversation.memory.append
].freeze
```

- Pass that list from `ToolExecution.call!`
- Keep the allowlist exact. Do not add `lane.kv.*`, prompt-buffer methods, or general callback expansion in this task.

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/test/services/agent_rpc/lifecycle_caller_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/cybros/programmable_agent/tool_execution.rb cybros/test/services/agent_rpc/lifecycle_caller_test.rb cybros/agents/claw/test/support/callback_harness.rb
git commit -m "feat: allow memory callbacks during tool execution"
```

### Task 7: Add A Conversation-Owned Memory Kernel Surface

**Files:**
- Create: `cybros/app/services/agent_rpc/kernel_services/conversation_memory.rb`
- Modify: `cybros/app/services/agent_rpc/callback_dispatcher.rb`
- Create: `cybros/test/services/agent_rpc/kernel_services/conversation_memory_test.rb`
- Test: `cybros/test/models/agent_rpc_operation_receipt_test.rb`

**Step 1: Write the failing test**

Add tests for:

- `get` returning the conversation memory body
- `put` replacing the document
- `append` appending text
- all operations being conversation-scoped, not lane-scoped
- `put` and `append` replaying idempotently by `operation_id`

**Step 2: Run test to verify it fails**

Run:

- `bundle exec ruby -Itest cybros/test/services/agent_rpc/kernel_services/conversation_memory_test.rb`
- `bundle exec ruby -Itest cybros/test/models/agent_rpc_operation_receipt_test.rb`

Expected: FAIL because the service and dispatcher routes do not exist.

**Step 3: Write minimal implementation**

Use a single conversation-scoped logical key on the Cybros side and hide the backing detail behind the service.

Contract rules:

- `conversation.memory.get` is a pure read
- `conversation.memory.put` and `conversation.memory.append` are mutating callback methods
- mutating methods must go through the normal callback mutation receipt path and therefore require `operation_id`
- no lane-local semantics leak through the public contract

Start with a response shape like:

```json
{
  "document": {
    "kind": "conversation_memory",
    "body": "current memory contents"
  }
}
```

**Step 4: Run test to verify it passes**

Run:

- `bundle exec ruby -Itest cybros/test/services/agent_rpc/kernel_services/conversation_memory_test.rb`
- `bundle exec ruby -Itest cybros/test/models/agent_rpc_operation_receipt_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/app/services/agent_rpc/kernel_services/conversation_memory.rb cybros/app/services/agent_rpc/callback_dispatcher.rb cybros/test/services/agent_rpc/kernel_services/conversation_memory_test.rb cybros/test/models/agent_rpc_operation_receipt_test.rb
git commit -m "feat: add conversation memory kernel service"
```

### Task 8: Add Agent-Side Memory Tools Backed By The Conversation Memory Contract

**Files:**
- Create: `cybros/agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/application.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Test: `cybros/test/integration/agent_runtime_binding_cutover_test.rb`

**Step 1: Write the failing test**

Add tests for:

- `memory_store` writing through callbacks
- `memory_get` reading back the document
- `memory_search` finding content from the conversation memory body

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because memory tools are not yet present in the catalog or executor.

**Step 3: Write minimal implementation**

Add these tools to the catalog:

```ruby
{ logical_tool_name: "memory_search", implementation_ref: "claw:memory_search", execution_mode: "serial" }
{ logical_tool_name: "memory_get", implementation_ref: "claw:memory_get", execution_mode: "serial" }
{ logical_tool_name: "memory_store", implementation_ref: "claw:memory_store", execution_mode: "serial" }
```

Keep V1 search simple:

- full-document scan
- line/snippet matches
- no embeddings yet

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb cybros/agents/claw/lib/cybros/agents/claw/application.rb cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb cybros/agents/claw/test/integration/rpc_contract_test.rb cybros/test/integration/agent_runtime_binding_cutover_test.rb
git commit -m "feat: add claw conversation memory tools"
```

### Task 9: Rebuild Claw Prompt Assembly Around Bootstrap Sections And DAG-Owned Prompt Modes

**Files:**
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`
- Modify: `cybros/agents/claw/prompts/system.md.liquid`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Test: `cybros/test/lib/agent_core/dag/prompt_assembly_test.rb`
- Test: `cybros/test/integration/programmable_agent_execution_context_test.rb`

**Step 1: Write the failing test**

Add tests proving:

- main sessions include Tooling, Safety, Workspace, Documentation, Current Date & Time, Runtime, and injected bootstrap context
- bootstrap injection includes bundled/profile sources (`AGENTS`, `SOUL`, `USER`, synthesized `TOOLS`) and conversation memory excerpts
- prompt mode is selected from Cybros-authored runtime context, using delegated execution signals such as `execution_context.execution_scope == "subagent"` or equivalent subagent metadata, not fixture-only branches
- subagent/minimal runs inject only the minimal bootstrap set and omit the full memory body

**Step 2: Run test to verify it fails**

Run:

- `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`
- `bundle exec ruby -Itest cybros/test/integration/programmable_agent_execution_context_test.rb`

Expected: FAIL because the current hook only stages a flat bundled prompt.

**Step 3: Write minimal implementation**

Refactor `before_agent_step` to assemble:

- identity/safety/tooling
- workspace context
- documentation pointer
- current date/time
- runtime metadata
- bundled or profile-derived `SOUL` / `USER`
- conversation memory excerpt

Mode-selection rules:

- use Cybros execution context to distinguish primary vs delegated runs
- keep delegated execution itself DAG-owned
- do not add a `claw`-local subagent routing shortcut

**Step 4: Run test to verify it passes**

Run:

- `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`
- `bundle exec ruby -Itest cybros/test/lib/agent_core/dag/prompt_assembly_test.rb`
- `bundle exec ruby -Itest cybros/test/integration/programmable_agent_execution_context_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb cybros/agents/claw/prompts/system.md.liquid cybros/agents/claw/test/integration/rpc_contract_test.rb cybros/test/lib/agent_core/dag/prompt_assembly_test.rb cybros/test/integration/programmable_agent_execution_context_test.rb
git commit -m "feat: assemble claw prompt from bootstrap sections and runtime prompt modes"
```

### Task 10: Add Bootstrap Budgeting, Truncation Markers, And Warning Surfaces

**Files:**
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`
- Modify: `cybros/agents/claw/prompts/system.md.liquid`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Test: `cybros/test/lib/agent_core/dag/prompt_assembly_test.rb`

**Step 1: Write the failing test**

Add tests proving that:

- bootstrap sources are capped by per-source and total injected budgets
- truncated sources carry explicit markers
- one warning surface is visible when prompt injection is shortened
- subagent/minimal mode still avoids full-memory injection after budgeting is applied

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/test/lib/agent_core/dag/prompt_assembly_test.rb`

Expected: FAIL because there is no budgeting or truncation signaling in the new bootstrap assembly.

**Step 3: Write minimal implementation**

Add OpenClaw-style bootstrap budgeting:

- per-source character cap
- total injected bootstrap cap
- truncation markers
- one warning surface when prompt truncation occurs

Keep budgeting local to prompt assembly. Do not re-implement context compaction logic inside `claw`.

**Step 4: Run test to verify it passes**

Run:

- `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`
- `bundle exec ruby -Itest cybros/test/lib/agent_core/dag/prompt_assembly_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb cybros/agents/claw/prompts/system.md.liquid cybros/agents/claw/test/integration/rpc_contract_test.rb cybros/test/lib/agent_core/dag/prompt_assembly_test.rb
git commit -m "feat: add claw bootstrap budgeting and truncation surfaces"
```

### Task 11: Add Web Search And Fetch On The Same Agent-Owned Tool Spine

**Files:**
- Create: `cybros/agents/claw/lib/cybros/agents/claw/tools/web_tools.rb`
- Create: `cybros/agents/claw/lib/cybros/agents/claw/tools/web_provider.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/application.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Add tests proving that:

- `web_search` returns structured results when a backend is configured
- `web_fetch` returns structured page content
- when no backend is configured, the tools either disappear from the catalog or return a clear disabled error

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because web tools are not catalogued or implemented.

**Step 3: Write minimal implementation**

Start with a provider adapter boundary inside `claw` so the implementation can be swapped later without changing tool names.

Return structured payloads:

- `web_search`: `results[]`
- `web_fetch`: `title`, `url`, `content`

Backend readiness rule:

- choose or wire one backend that can actually be exercised in development before final proof
- record the backend selection in the task notes or proof report
- if no development-usable backend can be made available, stop here and surface a blocker instead of continuing to the final proof stage

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/claw/lib/cybros/agents/claw/tools/web_tools.rb cybros/agents/claw/lib/cybros/agents/claw/tools/web_provider.rb cybros/agents/claw/lib/cybros/agents/claw/application.rb cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb cybros/agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: add claw web tools"
```

### Task 12: Extend Cybros DAG Finalization And Context-Pressure Handling For `NO_REPLY` And Silent Memory Flush

**Files:**
- Modify: `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Modify: `cybros/lib/cybros/programmable_agent/hook_envelope.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/before_finalize_output.rb`
- Test: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Test: `cybros/test/lib/agent_core/dag/agent_output_finalization_test.rb`
- Test: `cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb`
- Test: `cybros/test/scenarios/dag/agent_core_context_cost_report_test.rb`

**Step 1: Write the failing test**

Add tests proving that:

- Cybros can complete a successful turn without leaking a user-visible assistant reply when the final output is intentionally silent
- the system does not fall back to the draft provider output in that silent-finalization case
- context pressure can enqueue a memory flush task through the normal DAG hook path
- the flush does not create a second transcript system or hidden `claw` loop
- subagent minimal mode still avoids full-memory prompt injection

**Step 2: Run test to verify it fails**

Run:

- `bundle exec ruby -Itest cybros/test/lib/agent_core/dag/agent_output_finalization_test.rb`
- `bundle exec ruby -Itest cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb`

Expected: FAIL because the current finalization path falls back to the draft output when no message is emitted.

**Step 3: Write minimal implementation**

This task is Cybros-owned first, `claw`-owned second.

Implementation rules:

- first add or extend a DAG/runtime finalization surface that can represent a successful silent finalization outcome
- if a new programmable hook contract signal is needed, add it in Cybros instead of encoding hidden semantics in `claw`
- then adapt `claw` hooks to use that surface for pure `NO_REPLY` suppression and silent memory flush handling
- keep task creation inside normal hook envelopes and DAG node creation

The first version can remain heuristic:

- if context pressure suggests compaction
- and memory tools are present
- enqueue a memory write task before final compaction
- suppress pure `NO_REPLY` finalized replies through the DAG-owned silent finalization path
- strip terminal silent tokens from mixed finalized output to mirror OpenClaw reply shaping more closely

**Step 4: Run test to verify it passes**

Run:

- `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`
- `bundle exec ruby -Itest cybros/test/lib/agent_core/dag/agent_output_finalization_test.rb`
- `bundle exec ruby -Itest cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb`
- `bundle exec ruby -Itest cybros/test/scenarios/dag/agent_core_context_cost_report_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/agent_core/dag/executors/agent_message_executor.rb cybros/lib/cybros/programmable_agent/hook_envelope.rb cybros/agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb cybros/agents/claw/lib/cybros/agents/claw/hooks/before_finalize_output.rb cybros/agents/claw/test/integration/rpc_contract_test.rb cybros/test/lib/agent_core/dag/agent_output_finalization_test.rb cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb cybros/test/scenarios/dag/agent_core_context_cost_report_test.rb
git commit -m "feat: add DAG-owned silent finalization and memory flush handling"
```

### Task 13: Run A Reference-Based OpenClaw Parity Audit

**Files:**
- Create: `cybros/docs/reports/2026-03-15-claw-openclaw-parity-report.md`

**Step 1: Write the parity checklist**

Create a report template that lists each accepted capability with:

- Cybros implementation files
- OpenClaw reference docs
- OpenClaw reference source files
- expected parity behavior
- intentional divergence if any

At minimum cover:

- tool surface and prompt modes
- prompt/bootstrap sections and truncation behavior
- memory tool semantics
- web tool semantics
- `NO_REPLY` and pre-compaction memory flush
- Cybros-owned DAG/runtime responsibilities vs `claw`-owned tooling and prompt responsibilities

**Step 2: Run the targeted verification commands**

Run:

- `bundle exec ruby -Itest cybros/agents/claw/test/integration/rpc_contract_test.rb`
- `bundle exec ruby -Itest cybros/test/lib/agent_core/dag/prompt_assembly_test.rb`
- `bundle exec ruby -Itest cybros/test/integration/programmable_agent_execution_context_test.rb`
- `bundle exec ruby -Itest cybros/test/services/agent_rpc/lifecycle_caller_test.rb`
- `bundle exec ruby -Itest cybros/test/services/agent_rpc/kernel_services/conversation_memory_test.rb`
- `bundle exec ruby -Itest cybros/test/models/agent_rpc_operation_receipt_test.rb`
- `bundle exec ruby -Itest cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`
- `bundle exec ruby -Itest cybros/test/lib/agent_core/dag/agent_output_finalization_test.rb`
- `bundle exec ruby -Itest cybros/test/scenarios/dag/agent_core_context_cost_report_test.rb`

Expected: PASS

**Step 3: Compare behavior with OpenClaw references**

Use these references while filling the report:

- `references/openclaw/src/agents/tool-catalog.ts`
- `references/openclaw/src/agents/system-prompt.ts`
- `references/openclaw/src/agents/tools/memory-tool.ts`
- `references/openclaw/src/agents/tools/web-search.ts`
- `references/openclaw/src/agents/tools/web-fetch.ts`
- `references/openclaw/src/auto-reply/tokens.ts`
- `references/openclaw/docs/zh-CN/reference/session-management-compaction.md`
- `references/openclaw/src/agents/pi-embedded-runner/run.ts`
- `references/openclaw/src/agents/pi-embedded-subscribe.ts`

Mark every line item as one of:

- `matched`
- `matched with intentional divergence`
- `missing`

Do not declare the work complete if any required capability remains `missing`.

**Step 4: Commit**

```bash
git add cybros/docs/reports/2026-03-15-claw-openclaw-parity-report.md
git commit -m "docs: add claw openclaw parity report"
```

### Task 14: Run A Real Development Conversation Proof With The Configured Codex Subscription

**Files:**
- Create: `cybros/docs/reports/2026-03-15-claw-openclaw-proof.md`

**Step 1: Prepare a deterministic proof environment**

From `cybros/`:

- ensure PostgreSQL is running if the local environment requires it
- start the development stack with `bin/dev`
- ensure the initial owner/setup flow is already complete
- confirm the configured Codex provider can answer in one fresh conversation before the proof sequence starts
- confirm the chosen `web_search` backend is actually reachable in development

If needed for deterministic validation, temporarily lower development-only context-pressure / compaction thresholds so memory flush behavior can be triggered on demand.

Record in the report:

- environment date/time
- model/provider actually used
- proof conversation id
- proof lane ids
- chosen web backend

If the Codex provider or required web backend is unavailable, stop here and report a blocker instead of running a partial proof.

**Step 2: Run the proof task sequence**

Use one real conversation and, when needed, a branched lane to execute these tasks in order:

1. Coding loop proof:
   - ask the agent to inspect files in the conversation workspace
   - ask it to edit a scratch file
   - ask it to apply a patch
   - ask it to run a command and explain the result
2. Memory proof:
   - tell the agent to remember a durable fact or preference
   - ask a later-turn recall question that requires `memory_search` / `memory_get`
3. Branch proof:
   - create a branched lane
   - ask for the remembered fact there and confirm shared conversation memory
4. Web proof:
   - ask for a search-driven answer requiring `web_search`
   - ask for a follow-up page read requiring `web_fetch`
5. Subagent proof:
   - ask for a bounded delegation task
   - confirm the work ran through Cybros' normal subagent path
   - confirm the delegated execution used minimal prompt behavior
6. Silent flush proof:
   - drive context pressure high enough to trigger the silent memory flush path
   - confirm no user-visible `NO_REPLY` leakage
   - confirm the flush traveled through normal DAG task/activity surfaces

**Step 3: Capture evidence**

For each proof step, capture in the report:

- exact user prompt
- key tool calls observed
- final assistant-visible reply, or explicit absence of one for silent cases
- whether the behavior matched the OpenClaw reference
- any intentional divergence

Include conversation activity identifiers, subagent identifiers, or transcript excerpts precise enough that another engineer can replay the inspection.

**Step 4: Gate completion on proof**

Do not mark the implementation complete until:

- all proof steps pass
- the report is written
- any divergence from OpenClaw is explicitly documented and accepted
- no proof step depends on a hidden `claw`-local loop that bypasses Cybros DAG/runtime surfaces

**Step 5: Commit**

```bash
git add cybros/docs/reports/2026-03-15-claw-openclaw-proof.md
git commit -m "docs: add claw openclaw proof report"
```

## Explicit Follow-Up (Not In This Phase)

These are intentionally excluded from the current implementation and acceptance scope, but should be preserved as the next design backlog:

- `A3`: profile self-mutation
  - agent-owned/profile-owned state only
  - likely scope: `SOUL`, `USER`
  - explicit user intent required
  - no Cybros platform config writes, no deployment mutation, no restart semantics
- later: full agent-program self-upgrade / platform self-update
  - OpenClaw-like `config.apply` / `update.run` parity is a separate control-plane problem
  - requires independent design for authorization, audit, rollout/restart behavior, and recovery semantics
