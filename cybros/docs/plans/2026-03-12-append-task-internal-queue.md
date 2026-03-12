# Append Task Internal Queue Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor turn-scoped `create_task(append)` so append work enters a durable turn-internal queue before later materializing into DAG task nodes.

**Architecture:** Introduce a first-class durable queue model for turn-owned append work, keep `RunDraft` scoped to planning, and keep DAG nodes as execution truth only after materialization. `on_lane_first_user_message` title generation and branch summary follow-up become the primary acceptance scenarios, while `on_conversation_created` remains outside the queue as the control case.

**Tech Stack:** Ruby on Rails, ActiveRecord, DAG graph runtime, programmable-agent hook executor, bootstrap authority tools, queue-backed scheduler/materializer, Minitest, Playwright E2E

---

### Task 1: Lock The Acceptance Scenarios With Failing Tests

**Files:**
- Modify: `cybros/test/integration/bootstrap_lifecycle_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/hook_action_executor_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb`
- Modify: `cybros/test/e2e/bootstrap_hooks.spec.ts`

**Step 1: Write the failing test**

Cover:

- main-lane `on_lane_first_user_message` title generation no longer produces an immediate DAG task as the direct side effect of append admission
- branch-lane `on_lane_first_user_message` summary follow-up is treated as distinct lane-scoped append work
- `on_conversation_created` remains outside the turn queue
- replay/idempotency on lane-first-user bootstrap does not duplicate append work

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/bootstrap_lifecycle_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/lib/cybros/programmable_agent/hook_envelope_test.rb`

Expected: FAIL because append still materializes DAG tasks immediately.

**Step 3: Write minimal implementation**

Implement only enough test scaffolding and expectations to express the queue-backed acceptance criteria.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/bootstrap_lifecycle_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/lib/cybros/programmable_agent/hook_envelope_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add test/integration/bootstrap_lifecycle_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/lib/cybros/programmable_agent/hook_envelope_test.rb test/e2e/bootstrap_hooks.spec.ts
git commit -m "test: lock append queue acceptance scenarios"
```

### Task 2: Introduce Durable Turn-Internal Queue Rows

**Files:**
- Create: `cybros/app/models/turn_internal_task.rb`
- Create: `cybros/db/migrate/*_create_turn_internal_tasks.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/dag/graph.rb`
- Create: `cybros/test/models/turn_internal_task_test.rb`
- Modify: `cybros/test/models/dag/graph_test.rb`

**Step 1: Write the failing test**

Cover:

- durable queue rows can be created for a turn/lane/source hook
- queue rows preserve FIFO position
- queue rows enforce source-idempotent uniqueness
- queue rows track lifecycle independently from DAG nodes

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/turn_internal_task_test.rb test/models/dag/graph_test.rb`

Expected: FAIL because the queue model and schema do not exist yet.

**Step 3: Write minimal implementation**

Implement:

- `TurnInternalTask` model
- migration/schema wiring
- minimal associations/helpers from conversation/graph
- queue status enum/validation and idempotency constraint

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/turn_internal_task_test.rb test/models/dag/graph_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/models/turn_internal_task.rb db/migrate/*_create_turn_internal_tasks.rb app/models/conversation.rb app/models/dag/graph.rb test/models/turn_internal_task_test.rb test/models/dag/graph_test.rb
git commit -m "feat: add durable turn internal task rows"
```

### Task 3: Refactor Append Admission To Enqueue Instead Of Materialize

**Files:**
- Modify: `cybros/lib/cybros/programmable_agent/hook_action_executor.rb`
- Modify: `cybros/lib/cybros/programmable_agent/hook_envelope.rb`
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/hook_action_executor_test.rb`
- Modify: `cybros/test/integration/bootstrap_lifecycle_test.rb`
- Modify: `cybros/test/integration/programmable_agent_hooks_test.rb`

**Step 1: Write the failing test**

Cover:

- turn-scoped append hooks create queue rows instead of immediate DAG nodes
- `on_lane_first_user_message` append work is admitted into the queue
- `after_task_notice`, `after_subagent_result`, `on_context_pressure`, and `before_finalize_output` still validate append policy correctly
- `on_conversation_created` remains on its existing non-turn bootstrap path

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/integration/bootstrap_lifecycle_test.rb test/integration/programmable_agent_hooks_test.rb`

Expected: FAIL because append still calls immediate DAG materialization.

**Step 3: Write minimal implementation**

Implement:

- append admission path that persists `TurnInternalTask` rows
- queue-time freezing of routing metadata needed later
- no change to `prepend`
- preservation of existing bootstrap/non-bootstrap boundaries

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/integration/bootstrap_lifecycle_test.rb test/integration/programmable_agent_hooks_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add lib/cybros/programmable_agent/hook_action_executor.rb lib/cybros/programmable_agent/hook_envelope.rb lib/cybros/agent_runtime_resolver.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/integration/bootstrap_lifecycle_test.rb test/integration/programmable_agent_hooks_test.rb
git commit -m "feat: enqueue turn-scoped append tasks"
```

### Task 4: Build The Queue Materialization Scheduler

**Files:**
- Create: `cybros/app/services/turn_internal_tasks/materializer.rb`
- Modify: `cybros/lib/dag/runner.rb`
- Modify: `cybros/lib/dag/scheduler.rb`
- Modify: `cybros/app/models/turn_internal_task.rb`
- Modify: `cybros/test/lib/dag/scheduler_test.rb`
- Create: `cybros/test/services/turn_internal_tasks/materializer_test.rb`

**Step 1: Write the failing test**

Cover:

- FIFO queue ordering
- safe-prefix materialization
- first `serial` row blocks later rows
- a prefix of `parallel_safe` rows can materialize together
- queue rows backfill `materialized_task_node_id`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/turn_internal_tasks/materializer_test.rb test/lib/dag/scheduler_test.rb`

Expected: FAIL because there is no queue materializer/scheduler yet.

**Step 3: Write minimal implementation**

Implement:

- materializer service
- FIFO + safe-prefix selection
- status transitions `queued -> materializing -> materialized`
- scheduler hook-up so queued work eventually becomes DAG tasks

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/turn_internal_tasks/materializer_test.rb test/lib/dag/scheduler_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/turn_internal_tasks/materializer.rb lib/dag/runner.rb lib/dag/scheduler.rb app/models/turn_internal_task.rb test/services/turn_internal_tasks/materializer_test.rb test/lib/dag/scheduler_test.rb
git commit -m "feat: materialize append queue rows"
```

### Task 5: Freeze Queue-Time Execution Metadata And Parallel Policy

**Files:**
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/lib/cybros/bootstrap/tools.rb`
- Modify: `cybros/lib/cybros/programmable_agent/kernel_capability_catalog.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb`
- Modify: `cybros/test/lib/cybros/bootstrap/tools_test.rb`

**Step 1: Write the failing test**

Cover:

- queued rows freeze `execution_mode`
- queue materialization does not consult live surface state later
- `subagent_run` is the first `parallel_safe` family
- title generation and lane summary authority tasks remain `serial`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/lib/cybros/bootstrap/tools_test.rb`

Expected: FAIL because queue-time execution metadata is not persisted yet.

**Step 3: Write minimal implementation**

Implement:

- `execution_mode` propagation at enqueue time
- route-aware freezing onto the queue row
- initial metadata declarations for `serial` vs `parallel_safe`

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/lib/cybros/bootstrap/tools_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add lib/cybros/agent_runtime_resolver.rb lib/cybros/bootstrap/tools.rb lib/cybros/programmable_agent/kernel_capability_catalog.rb test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/lib/cybros/bootstrap/tools_test.rb
git commit -m "feat: freeze append queue execution metadata"
```

### Task 6: Implement Reset And Retry Semantics

**Files:**
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/dag/graph.rb`
- Modify: `cybros/app/models/turn_internal_task.rb`
- Modify: `cybros/test/integration/retry_generation_test.rb`
- Modify: `cybros/test/integration/bootstrap_lifecycle_test.rb`
- Create: `cybros/test/integration/turn_internal_task_reset_test.rb`

**Step 1: Write the failing test**

Cover:

- single-task retry preserves queued rows
- turn reset preserves turn head and user input
- turn reset cancels queued rows and clears turn-derived execution nodes
- replay after reset does not leak stale queued work

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/retry_generation_test.rb test/integration/bootstrap_lifecycle_test.rb test/integration/turn_internal_task_reset_test.rb`

Expected: FAIL because reset/retry do not yet coordinate queue rows with derived DAG state.

**Step 3: Write minimal implementation**

Implement:

- task-retry preservation rules
- turn-reset cancellation/reset state transitions
- coordinated cleanup between queue rows and derived DAG nodes

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/retry_generation_test.rb test/integration/bootstrap_lifecycle_test.rb test/integration/turn_internal_task_reset_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/models/conversation.rb app/models/dag/graph.rb app/models/turn_internal_task.rb test/integration/retry_generation_test.rb test/integration/bootstrap_lifecycle_test.rb test/integration/turn_internal_task_reset_test.rb
git commit -m "feat: add append queue reset semantics"
```

### Task 7: Re-Verify The Title And Branch Summary Acceptance Flows

**Files:**
- Modify: `cybros/test/e2e/bootstrap_hooks.spec.ts`
- Modify: `cybros/test/integration/bootstrap_lifecycle_test.rb`
- Modify: `cybros/docs/plans/2026-03-12-append-task-internal-queue-design.md`
- Modify: `cybros/docs/product/programmable_agents.md`
- Modify: `cybros/docs/product/agent_rpc.md`

**Step 1: Write the failing test/checklist**

Cover:

- main-lane title generation still succeeds through the queue-backed path
- branch-lane summary follow-up still appears as distinct append work
- docs correctly describe `on_lane_first_user_message` as the representative acceptance path for queue-backed append orchestration

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/bootstrap_lifecycle_test.rb`

Expected: FAIL until docs/tests align with the queue-backed implementation details.

**Step 3: Write minimal implementation**

Implement:

- any final test fixture/documentation alignment needed after the queue refactor
- explicit documentation of the acceptance scenarios and queue boundary

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/bootstrap_lifecycle_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add test/e2e/bootstrap_hooks.spec.ts test/integration/bootstrap_lifecycle_test.rb docs/plans/2026-03-12-append-task-internal-queue-design.md docs/product/programmable_agents.md docs/product/agent_rpc.md
git commit -m "docs: align append queue acceptance flows"
```

### Task 8: Fresh Verification

**Files:**
- Verify only

**Step 1: Run targeted suites**

Run: `bin/rails test test/integration/bootstrap_lifecycle_test.rb test/integration/programmable_agent_hooks_test.rb test/lib/cybros/programmable_agent/hook_action_executor_test.rb test/services/turn_internal_tasks/materializer_test.rb test/models/turn_internal_task_test.rb test/integration/turn_internal_task_reset_test.rb`

Expected: PASS

**Step 2: Run end-to-end bootstrap verification**

Run: `bunx playwright test test/e2e/bootstrap_hooks.spec.ts`

Expected: PASS

**Step 3: Run full CI**

Run: `bin/ci`

Expected: PASS

**Step 4: Final grep and diff cleanliness**

Run: `rg -n "immediate DAG materialization|append-only bootstrap|turn-internal queue" docs/product docs/plans test lib app`

Expected: Results match the new queue-backed design and do not contradict active product docs.

Run: `git diff --check`

Expected: no output

**Step 5: Commit**

```bash
git add -A
git commit -m "test: verify append task internal queue"
```
