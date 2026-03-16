# Operation Sequence Cutover Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor Cybros so admitted tool use and bundled-agent programmed operations share a queue-first operation path built on `turn_internal_tasks`, while keeping `memory` in `claw` as an explicit policy exception.

**Architecture:** Introduce thin `OperationCall` and `OperationSequence` primitives, validate them close to their current entry points, and flush them into existing `turn_internal_tasks` rows instead of creating ad hoc DAG task nodes directly. Reuse the existing scheduler/materializer path, collapse duplicate workspace bootstrap logic, delete dead compatibility surfaces, and accept destructive database resets instead of carrying compatibility shims.

**Tech Stack:** Ruby on Rails, ActiveRecord, DAG runtime, programmable-agent hooks, bundled `claw` Ruby agent package, Minitest, Playwright E2E, PostgreSQL, Bun dev server, OpenRouter-backed live model validation

---

## Execution Preconditions

- Before any Rails command, run `pg_isready`.
- If PostgreSQL is not accepting connections, start it using the repository/environment instructions before continuing.
- If the refactor makes existing development or test data incompatible, reset the database instead of adding compatibility code.
- Treat `bin/ci`, `bin/ci_e2e`, and one real `bin/dev` conversation as required acceptance gates, not optional follow-up checks.

### Task 1: Lock The Unified-Path Acceptance Criteria

**Files:**
- Modify: `cybros/test/integration/programmable_agent_execution_test.rb`
- Modify: `cybros/test/integration/programmable_agent_tool_routing_test.rb`
- Modify: `cybros/test/integration/bootstrap_lifecycle_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/hook_action_executor_test.rb`
- Modify: `cybros/test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`

**Step 1: Write the failing test**

Cover these acceptance scenarios:

- a validated direct tool call no longer creates its task node directly inside `AgentMessageExecutor`
- a hook-authored bootstrap sequence lands in `turn_internal_tasks` in stable order
- a validated `subagent_spawn` or `subagent_run` call also uses the queue-first path
- invalid or denied operations do not create admitted queue rows

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/integration/programmable_agent_execution_test.rb test/integration/programmable_agent_tool_routing_test.rb test/integration/bootstrap_lifecycle_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`

Expected: FAIL because direct tool calls still materialize DAG task nodes immediately and the queue path is not yet shared.

**Step 3: Write minimal implementation**

Only change test code and fixtures needed to express the cutover expectations. Do not implement runtime changes in this step.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/integration/programmable_agent_execution_test.rb test/integration/programmable_agent_tool_routing_test.rb test/integration/bootstrap_lifecycle_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/test/integration/programmable_agent_execution_test.rb cybros/test/integration/programmable_agent_tool_routing_test.rb cybros/test/integration/bootstrap_lifecycle_test.rb cybros/test/lib/cybros/programmable_agent/hook_action_executor_test.rb cybros/test/lib/agent_core/dag/runtime_surface_error_handling_test.rb
git commit -m "test: lock unified operation path acceptance"
```

### Task 2: Introduce Thin OperationCall And OperationSequence Primitives

**Files:**
- Create: `cybros/lib/cybros/programmable_agent/operation_call.rb`
- Create: `cybros/lib/cybros/programmable_agent/operation_sequence.rb`
- Modify: `cybros/lib/cybros/programmable_agent.rb`
- Create: `cybros/test/lib/cybros/programmable_agent/operation_call_test.rb`
- Create: `cybros/test/lib/cybros/programmable_agent/operation_sequence_test.rb`

**Step 1: Write the failing test**

Cover:

- `OperationCall.tool(...)` normalizes `tool_call_id`, `logical_tool_name`, `arguments`, `reason`, `origin`, `approval_hint`, and `idempotency_key`
- `OperationCall.subagent_spawn(...)` preserves the runtime tool name `subagent_spawn`
- `OperationSequence` accepts ordered calls and serializes them to queue-ready payloads

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/lib/cybros/programmable_agent/operation_call_test.rb test/lib/cybros/programmable_agent/operation_sequence_test.rb`

Expected: FAIL because the primitives do not exist yet.

**Step 3: Write minimal implementation**

Implement:

```ruby
OperationCall.tool(logical_tool_name:, arguments:, reason:, origin:, tool_call_id: nil, approval_hint: nil, idempotency_key: nil)
OperationCall.subagent_spawn(arguments:, reason:, origin:, tool_call_id: nil, approval_hint: nil, idempotency_key: nil)
OperationSequence.new(origin:)
```

Keep them as in-memory helpers only. Do not add a database table.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/lib/cybros/programmable_agent/operation_call_test.rb test/lib/cybros/programmable_agent/operation_sequence_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/lib/cybros/programmable_agent/operation_call.rb cybros/lib/cybros/programmable_agent/operation_sequence.rb cybros/lib/cybros/programmable_agent.rb cybros/test/lib/cybros/programmable_agent/operation_call_test.rb cybros/test/lib/cybros/programmable_agent/operation_sequence_test.rb
git commit -m "feat: add thin operation sequence primitives"
```

### Task 3: Teach TurnInternalTask Rows To Carry The Unified Call Envelope

**Files:**
- Modify: `cybros/app/models/turn_internal_task.rb`
- Modify: `cybros/app/services/turn_internal_tasks/materializer.rb`
- Modify: `cybros/app/services/statistics/tool_call_fact_projector.rb`
- Modify: `cybros/test/models/turn_internal_task_test.rb`
- Modify: `cybros/test/services/turn_internal_tasks/materializer_test.rb`
- Modify: `cybros/test/models/statistics/tool_call_fact_projector_test.rb`

**Step 1: Write the failing test**

Cover:

- queue rows can preserve `reason`, `origin`, `approval_hint`, `idempotency_key`, `sequence_id`, and `step_index` without a new durable entity
- materialized task nodes project the same tool-call envelope fields
- projected statistics still work for queue-materialized task nodes

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/turn_internal_task_test.rb test/services/turn_internal_tasks/materializer_test.rb test/models/statistics/tool_call_fact_projector_test.rb`

Expected: FAIL because the queue rows and materializer do not yet preserve the new envelope fields.

**Step 3: Write minimal implementation**

Prefer storing the new queue metadata inside `input` and `authored_metadata`. Only add a schema migration if a required field cannot be represented cleanly in the existing row shape.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/turn_internal_task_test.rb test/services/turn_internal_tasks/materializer_test.rb test/models/statistics/tool_call_fact_projector_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/app/models/turn_internal_task.rb cybros/app/services/turn_internal_tasks/materializer.rb cybros/app/services/statistics/tool_call_fact_projector.rb cybros/test/models/turn_internal_task_test.rb cybros/test/services/turn_internal_tasks/materializer_test.rb cybros/test/models/statistics/tool_call_fact_projector_test.rb
git commit -m "feat: preserve operation envelope on queued tasks"
```

### Task 4: Queue Validated Direct Tool Calls Instead Of Creating DAG Tasks Inline

**Files:**
- Modify: `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Modify: `cybros/lib/agent_core/dag/executors/task_executor.rb`
- Modify: `cybros/test/integration/programmable_agent_execution_test.rb`
- Modify: `cybros/test/integration/programmable_agent_tool_routing_test.rb`
- Modify: `cybros/test/lib/agent_core/dag/task_executor_runtime_surface_test.rb`
- Modify: `cybros/test/scenarios/dag/programmable_agent_subagent_fanout_test.rb`

**Step 1: Write the failing test**

Cover:

- validated direct tool calls are admitted into `turn_internal_tasks`
- required approval is computed before admission and survives queue materialization
- queue-materialized direct calls still execute through `TaskExecutor`
- `subagent_run` keeps its `parallel_safe` execution behavior after the queue cutover

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/integration/programmable_agent_execution_test.rb test/integration/programmable_agent_tool_routing_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/scenarios/dag/programmable_agent_subagent_fanout_test.rb`

Expected: FAIL because direct tool calls still create DAG task nodes inside `expand_tool_loop!`.

**Step 3: Write minimal implementation**

Implement:

- validation and approval preview stay near `expand_tool_loop!`
- admitted calls are converted into `OperationCall` objects
- admitted calls are flushed into `turn_internal_tasks`
- `TaskExecutor` continues to execute queue-materialized tasks without a second executor path

Do not add a new durable queue model.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/integration/programmable_agent_execution_test.rb test/integration/programmable_agent_tool_routing_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/scenarios/dag/programmable_agent_subagent_fanout_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/lib/agent_core/dag/executors/agent_message_executor.rb cybros/lib/agent_core/dag/executors/task_executor.rb cybros/test/integration/programmable_agent_execution_test.rb cybros/test/integration/programmable_agent_tool_routing_test.rb cybros/test/lib/agent_core/dag/task_executor_runtime_surface_test.rb cybros/test/scenarios/dag/programmable_agent_subagent_fanout_test.rb
git commit -m "feat: queue direct tool calls before execution"
```

### Task 5: Route Programmable Hook Operations Through The Same Queue Path

**Files:**
- Modify: `cybros/lib/cybros/programmable_agent/hook_envelope.rb`
- Modify: `cybros/lib/cybros/programmable_agent/hook_action_executor.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/hook_action_executor_test.rb`
- Modify: `cybros/test/integration/programmable_agent_hooks_test.rb`

**Step 1: Write the failing test**

Cover:

- hook-authored operations and direct tool calls now serialize to the same queue envelope
- ordered bootstrap operations preserve stable queue order
- no new durable entity is introduced for hook-authored sequences
- old `execution_target` proposal branches are gone from the hook contract

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/lib/cybros/programmable_agent/hook_envelope_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/integration/programmable_agent_hooks_test.rb`

Expected: FAIL because hook-created tasks still use the older task-specific admission path and dead compatibility logic still exists.

**Step 3: Write minimal implementation**

Implement:

- map hook-authored operations onto `OperationCall` or `OperationSequence`
- reuse existing `turn_internal_tasks` admission
- remove dead `execution_target.list` and `planning.execution_target_proposal` handling instead of translating it

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/lib/cybros/programmable_agent/hook_envelope_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/integration/programmable_agent_hooks_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/lib/cybros/programmable_agent/hook_envelope.rb cybros/lib/cybros/programmable_agent/hook_action_executor.rb cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb cybros/test/lib/cybros/programmable_agent/hook_action_executor_test.rb cybros/test/integration/programmable_agent_hooks_test.rb
git commit -m "feat: unify hook operations with queue admission"
```

### Task 6: Rewrite Bundled Claw Bootstrap Hooks And Remove Production Fixture Branches

**Files:**
- Modify: `agents/claw/lib/cybros/agents/claw/hooks/on_conversation_created.rb`
- Modify: `agents/claw/lib/cybros/agents/claw/hooks/on_lane_first_user_message.rb`
- Modify: `agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb`
- Modify: `agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`
- Modify: `agents/claw/test/integration/rpc_contract_test.rb`
- Modify: `agents/claw/test/support/contract_assertions.rb`

**Step 1: Write the failing test**

Cover:

- bootstrap hooks emit ordered queueable operation intents instead of relying on ad hoc task payload assumptions
- context-pressure memory flush remains `claw` policy, but now uses the shared admitted operation envelope
- production `before_agent_step` no longer ships fixture/scenario behavior

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/agents/claw && bin/test`

Expected: FAIL because the bundled hook payloads and contract assertions still describe the older task-oriented contract and fixture behavior.

**Step 3: Write minimal implementation**

Keep `memory` in `claw`. Do not move callback-backed `memory` policy into `cybros`. Only change how hook-authored work is described and admitted.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/agents/claw && bin/test`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add agents/claw/lib/cybros/agents/claw/hooks/on_conversation_created.rb agents/claw/lib/cybros/agents/claw/hooks/on_lane_first_user_message.rb agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb agents/claw/test/integration/rpc_contract_test.rb agents/claw/test/support/contract_assertions.rb
git commit -m "refactor: rewrite claw hook operation payloads"
```

### Task 7: Collapse Workspace Bootstrap And Kernel Authority Tasks

**Files:**
- Modify: `cybros/app/services/agents/workspace_bootstrap.rb`
- Modify: `cybros/app/services/agents/workspace_initializer.rb`
- Modify: `cybros/lib/cybros/bootstrap/tools.rb`
- Modify: `agents/claw/lib/cybros/agents/claw/workspace_bootstrap.rb`
- Modify: `cybros/test/services/agents/bootstrap_bundled_default_service_test.rb`
- Modify: `agents/claw/test/integration/rpc_contract_test.rb`
- Modify: `cybros/test/integration/bootstrap_lifecycle_test.rb`

**Step 1: Write the failing test**

Cover:

- only one workspace bootstrap implementation survives
- bootstrap authority stays in `cybros`
- bundled `claw` still defines the bootstrap content it needs
- `cybros_seed_message`, `cybros_generate_title`, and `cybros_enqueue_lane_summary` still work through the queue-first path

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb test/integration/bootstrap_lifecycle_test.rb`

Expected: FAIL because workspace bootstrap is still duplicated and authority/tool admission is not fully unified.

**Step 3: Write minimal implementation**

Collapse the duplication instead of adding adapters. If the simpler cut is to delete one implementation and update callers immediately, do that.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb test/integration/bootstrap_lifecycle_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/app/services/agents/workspace_bootstrap.rb cybros/app/services/agents/workspace_initializer.rb cybros/lib/cybros/bootstrap/tools.rb agents/claw/lib/cybros/agents/claw/workspace_bootstrap.rb cybros/test/services/agents/bootstrap_bundled_default_service_test.rb agents/claw/test/integration/rpc_contract_test.rb cybros/test/integration/bootstrap_lifecycle_test.rb
git commit -m "refactor: collapse workspace bootstrap ownership"
```

### Task 8: Destructive Cleanup, Full Verification, And Live Conversation Proof

**Files:**
- Modify: `cybros/docs/plans/2026-03-17-operation-sequence-cutover-design.md`
- Modify: `cybros/docs/plans/2026-03-17-operation-sequence-cutover.md`

**Step 1: Write the failing test**

Add or tighten only the last missing regression coverage discovered during cleanup. Do not start this task by editing docs first.

**Step 2: Run targeted verification**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
pg_isready
```

If PostgreSQL is not ready, start it using the repository/environment instructions before continuing.

If the refactor made local rows incompatible, reset databases before the full suite:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros
bin/rails db:drop db:create db:schema:load
RAILS_ENV=test bin/rails db:drop db:create db:schema:load
```

Then run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/agents/claw
bin/test

cd /Users/jasl/Workspaces/Cybros/cybros/cybros
bin/rails test
bin/ci
bin/ci_e2e
```

Expected: PASS

**Step 3: Run live `bin/dev` validation**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros
bin/dev
```

Manual acceptance checklist:

- complete one real conversation using the configured OpenRouter-backed model from `.env`
- verify the conversation still boots and returns a usable answer
- trigger at least one normal tool call and verify it executes successfully
- verify a bootstrap-generated operation sequence lands on the queue and completes
- verify a `subagent_spawn` or `subagent_run` operation still works end-to-end

Only stop `bin/dev` after collecting the evidence needed to prove the new path works.

**Step 4: Update docs and rerun the smallest impacted tests**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/integration/bootstrap_lifecycle_test.rb test/integration/programmable_agent_execution_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/app cybros/lib cybros/test cybros/docs/plans/2026-03-17-operation-sequence-cutover-design.md cybros/docs/plans/2026-03-17-operation-sequence-cutover.md agents/claw/lib agents/claw/test
git commit -m "refactor: cut over to queue-first operation sequences"
```
