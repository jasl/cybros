# Runtime Tool Reliability Statistics Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a runtime-native tool reliability statistics system that records one canonical fact per tool call attempt, separates model tool-calling quality from tool execution quality, and surfaces runtime-only metrics on the existing `Statistics` page.

**Architecture:** Introduce a durable `Statistics::ToolCallFact` table keyed by `task_node_id`, project facts from existing DAG/task truth plus same-turn agent metadata, and query the fact table through dedicated `Cybros::Statistics::*` services rather than ad hoc DAG JSON queries. While doing this, move the existing product-facing token usage reads out of `Cybros::LLM` and into the same `Statistics` service boundary so the `/statistics` page is internally coherent. Extend normal runtime entrypoints to tag `sample_origin = "runtime"` by default, store per-task repair attribution and tool failure taxonomy durably, and keep subagent child tool calls in the same dataset with `execution_scope = "subagent_child"` while preserving independent child conversations/graphs.

**Tech Stack:** Ruby 4.0, Rails 8 alpha, PostgreSQL 18, ActiveRecord models/migrations, ActiveSupport and integration tests, DAG task nodes, AgentCore tool loop/runtime executors, existing `StatisticsController`, ERB views.

## Scope boundary

This plan implements:

- canonical runtime-only tool-call facts
- product-facing statistics namespace cleanup
- per-task repair attribution
- stable tool failure taxonomy
- fact projection and backfill
- runtime-only reliability aggregation service
- `Statistics` page sections for model/tool reliability
- subagent child scope accounting

This plan explicitly does **not** implement:

- judge-based model eval
- mixing eval/debug samples into the default product statistics page
- provider-specific dashboard taxonomies as the primary metric model
- a second execution store for turn progress
- any DAG topology change for subagents
- route or controller renaming for `/statistics`

## Execution order and dependency constraints

Recommended order:

1. Task 1 (`statistics namespace cleanup`)
2. Task 2 (`fact schema and model`)
3. Task 3 (`sample origin plumbing`)
4. Task 4 (`per-task repair attribution`)
5. Task 5 (`tool failure taxonomy`)
6. Task 6 (`fact projector`)
7. Task 7 (`backfill service`)
8. Task 8 (`reliability aggregation service`)
9. Task 9 (`statistics page runtime reliability UI`)
10. Task 10 (`subagent child scope accounting`)
11. Task 11 (`final docs and regression verification`)

Hard dependencies:

- Task 1 must land before Task 9 so the page uses one coherent `Statistics` naming boundary.
- Task 2 must land before everything that depends on the fact table.
- Task 3 must land before Tasks 6, 7, 8, and 9 because the runtime-only boundary depends on explicit sample origin.
- Task 4 must land before Task 6 because the projector needs durable per-task repair attribution.
- Task 5 must land before Task 6 because the projector needs durable failure classification.
- Task 6 must land before Tasks 7, 8, 9, and 10 because the fact table must be populated first.
- Task 7 should land before Task 9 so the page can be validated against rebuilt historical data, not only fresh rows.
- Task 8 must land before Tasks 9 and 10 because the UI should not aggregate directly from the table in view code.
- Task 10 must land before Task 11 so final verification covers subagent scope correctness.

## Acceptance criteria

This plan is complete only when all of the following are true:

- the default `Statistics` page only reads `sample_origin = "runtime"` for tool reliability metrics
- product-facing statistics services are organized under `Cybros::Statistics::*` rather than split across `Cybros::LLM` and other namespaces
- one canonical fact row exists per tool-call `task` node
- model-side and tool-side rates are reported separately
- `invalid_args` and `tool_not_found` count as model failures
- `policy_denied`, `awaiting_approval`, and `approval_rejected` are shown separately and do not count as model failures
- automatic tool name repair and tool args repair are attributed per task row
- tool failures are classified into the stable first-pass taxonomy
- subagent child tool calls are included with `execution_scope = "subagent_child"`
- manual reruns create new fact rows and do not inflate repair-assisted success
- a backfill path can rebuild facts from historical DAG truth
- eval/debug/replay are excluded from default runtime metrics

---

## Task 1: Move product-facing statistics services under a coherent namespace

### Task 1 Files

- Create: `cybros/lib/cybros/statistics/usage_stats.rb`
- Modify: `cybros/app/controllers/statistics_controller.rb`
- Modify: `cybros/test/integration/statistics_page_test.rb`
- Test: `cybros/test/lib/cybros/statistics/usage_stats_test.rb`
- Delete or stop referencing: `cybros/lib/cybros/llm/usage_stats.rb`

### Task 1 / Step 1: Write the failing test

Add tests that prove:

- token usage aggregation is available via `Cybros::Statistics::UsageStats`
- `StatisticsController` reads product-facing token usage through the new namespace
- existing `/statistics` token sections still behave the same

### Task 1 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/statistics/usage_stats_test.rb test/integration/statistics_page_test.rb
```

Expected: FAIL because token usage still lives under `Cybros::LLM::UsageStats`.

### Task 1 / Step 3: Write minimal implementation

Move the product-facing usage query service to:

- `Cybros::Statistics::UsageStats`

Update `StatisticsController` to use only `Cybros::Statistics::*` services.

Keep `DAG::UsageStats` untouched unless a small rename/doc clarification is needed; it is engine/debug scope, not product-page scope.

### Task 1 / Step 4: Run test to verify it passes

Run the same tests again.

Expected: PASS

### Task 1 / Step 5: Commit

```bash
git add cybros/lib/cybros/statistics/usage_stats.rb cybros/app/controllers/statistics_controller.rb cybros/test/integration/statistics_page_test.rb cybros/test/lib/cybros/statistics/usage_stats_test.rb
git rm cybros/lib/cybros/llm/usage_stats.rb
git commit -m "refactor: move product statistics services into statistics namespace"
```

## Task 2: Add the canonical `Statistics::ToolCallFact` schema and model

### Task 2 Files

- Create: `cybros/db/migrate/20260308130000_create_statistics_tool_call_facts.rb`
- Create: `cybros/app/models/statistics/tool_call_fact.rb`
- Modify: `cybros/db/schema.rb`
- Test: `cybros/test/models/statistics/tool_call_fact_test.rb`

### Task 2 / Step 1: Write the failing test

Add model tests that assert:

- `task_node_id` is unique
- `sample_origin`, `execution_scope`, `model_attempt_class`, `execution_readiness`, and `tool_outcome` only accept the frozen values
- `entered_execution` and `manual_retry` default correctly
- a row can store correlation ids, tool identifiers, timing, and failure metadata

### Task 2 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/models/statistics/tool_call_fact_test.rb
```

Expected: FAIL because no model or table exists yet.

### Task 2 / Step 3: Write minimal implementation

Implement:

- migration for `statistics_tool_call_facts`
- unique index on `task_node_id`
- practical query indexes for:
  - `sample_origin`
  - `user_id`
  - `model_ref`
  - `resolved_name`
  - `execution_scope`
  - effective day/timestamps
- `Statistics::ToolCallFact` model with enum/value validation helpers

Keep the schema normalized enough for filtering and aggregation, but do not add daily rollup tables yet.

### Task 2 / Step 4: Run test to verify it passes

Run the same test again.

Expected: PASS

### Task 2 / Step 5: Commit

```bash
git add cybros/db/migrate/20260308130000_create_statistics_tool_call_facts.rb cybros/app/models/statistics/tool_call_fact.rb cybros/db/schema.rb cybros/test/models/statistics/tool_call_fact_test.rb
git commit -m "feat: add tool call fact schema"
```

## Task 3: Add runtime sample-origin plumbing

### Task 3 Files

- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/lib/cybros/subagent/tools.rb`
- Modify: `cybros/lib/cybros/cli/dag_debug.rb`
- Test: `cybros/test/models/conversation_statistics_origin_test.rb`
- Test: `cybros/test/lib/cybros/debug/dag_debug_test.rb`

### Task 3 / Step 1: Write the failing tests

Add coverage that proves:

- normal user/runtime conversation entrypoints default `metadata["statistics"]["sample_origin"]` to `"runtime"`
- subagent child conversations inherit a non-nil statistics origin and remain runtime unless explicitly overridden
- debug CLI synthetic conversations are explicitly tagged as non-runtime
- missing origin is normalized during read/backfill, not left ambiguous

### Task 3 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/models/conversation_statistics_origin_test.rb test/lib/cybros/debug/dag_debug_test.rb
```

Expected: FAIL because sample origin is not plumbed today.

### Task 3 / Step 3: Write minimal implementation

Update conversation creation and special entrypoints so:

- normal app/user flows default to `"runtime"`
- non-runtime flows like DAG debug can set `"debug"`
- subagent child conversations copy or normalize a statistics origin alongside existing subagent metadata

Do not implement eval-origin plumbing yet; just make the contract explicit and future-safe.

### Task 3 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 3 / Step 5: Commit

```bash
git add cybros/app/models/conversation.rb cybros/lib/cybros/subagent/tools.rb cybros/lib/cybros/cli/dag_debug.rb cybros/test/models/conversation_statistics_origin_test.rb cybros/test/lib/cybros/debug/dag_debug_test.rb
git commit -m "feat: tag statistics sample origins"
```

## Task 4: Persist per-task repair attribution during tool expansion

### Task 4 Files

- Modify: `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Modify: `cybros/docs/agent_core/node_payloads.md`
- Test: `cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb`

### Task 4 / Step 1: Write the failing tests

Add or extend scenario coverage that proves:

- a first-pass executable task stores `arguments_resolution = "original"` and no repair flags
- a name-repaired task stores name repair attribution durably
- an args-repaired task stores arguments repair attribution durably
- a task repaired by both loops stores both flags
- `invalid_args` tasks store `arguments_resolution = "invalid"`

### Task 4 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/scenarios/dag/agent_core_dag_integration_flow_test.rb
```

Expected: FAIL because repair attribution is only available as aggregate turn metadata today.

### Task 4 / Step 3: Write minimal implementation

When expanding tool calls into task nodes, write durable task input fields:

- `arguments_resolution`
- `repair.tool_name`
- `repair.arguments`

Make sure this is set consistently for:

- executable tasks
- `invalid_args` tasks
- approval-gated tasks
- policy-denied/non-executed tool-call rows where attribution is still knowable

### Task 4 / Step 4: Run test to verify it passes

Run the same scenario test again.

Expected: PASS

### Task 4 / Step 5: Commit

```bash
git add cybros/lib/agent_core/dag/executors/agent_message_executor.rb cybros/docs/agent_core/node_payloads.md cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb
git commit -m "feat: persist per-task repair attribution"
```

## Task 5: Add stable tool failure taxonomy metadata

### Task 5 Files

- Modify: `cybros/lib/agent_core/resources/tools/tool.rb`
- Modify: `cybros/lib/agent_core/resources/tools/registry.rb`
- Modify: `cybros/lib/agent_core/resources/tools/tool_result.rb`
- Test: `cybros/test/lib/agent_core/resources/tools/tool_failure_taxonomy_test.rb`

### Task 5 / Step 1: Write the failing test

Add tests that prove:

- native validation failures map to `validation_error`
- uncaught native tool exceptions map to `implementation_error`
- MCP/remote transport failures can map to `remote_api_error`
- timeout/rate-limit/auth errors can be classified distinctly when recognizable
- `ToolResult.metadata["tool_execution"]` preserves `failure_class`, optional `failure_code`, and `retryable`

### Task 5 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/agent_core/resources/tools/tool_failure_taxonomy_test.rb
```

Expected: FAIL because tool failures do not have a stable taxonomy payload yet.

### Task 5 / Step 3: Write minimal implementation

Add a small taxonomy helper path so tool execution can return:

- `failure_class`
- `failure_code`
- `retryable`

Store it under `ToolResult.metadata["tool_execution"]`.

Keep the first pass broad and stable; do not overfit to provider-specific classes.

### Task 5 / Step 4: Run test to verify it passes

Run the same test again.

Expected: PASS

### Task 5 / Step 5: Commit

```bash
git add cybros/lib/agent_core/resources/tools/tool.rb cybros/lib/agent_core/resources/tools/registry.rb cybros/lib/agent_core/resources/tools/tool_result.rb cybros/test/lib/agent_core/resources/tools/tool_failure_taxonomy_test.rb
git commit -m "feat: add tool failure taxonomy metadata"
```

## Task 6: Project runtime task nodes into `Statistics::ToolCallFact`

### Task 6 Files

- Create: `cybros/app/services/statistics/tool_call_fact_projector.rb`
- Modify: `cybros/app/models/dag/node.rb`
- Test: `cybros/test/models/statistics/tool_call_fact_projector_test.rb`

### Task 6 / Step 1: Write the failing test

Add projector tests that prove:

- one tool-call `task` node upserts one fact row
- preflight tasks do not create rows
- `execution_readiness`, `entered_execution`, and `tool_outcome` are derived correctly from task state/output
- provider/model info is resolved from the upstream same-turn agent node
- manual retry rows get `manual_retry = true` and `retry_of_task_node_id`

### Task 6 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/models/statistics/tool_call_fact_projector_test.rb
```

Expected: FAIL because no projector exists and task updates do not populate the fact table.

### Task 6 / Step 3: Write minimal implementation

Implement a projector that:

- keys by `task_node_id`
- ignores non-tool-call tasks
- derives runtime fact fields from task input/output/state and same-turn agent metadata
- treats missing historical classification conservatively
- is safe to call repeatedly

Trigger it from durable task lifecycle writes using an `after_commit` path or similarly reliable hook.

### Task 6 / Step 4: Run test to verify it passes

Run the same test again.

Expected: PASS

### Task 6 / Step 5: Commit

```bash
git add cybros/app/services/statistics/tool_call_fact_projector.rb cybros/app/models/dag/node.rb cybros/test/models/statistics/tool_call_fact_projector_test.rb
git commit -m "feat: project task nodes into tool call facts"
```

## Task 7: Add a backfill/rebuild path for historical runtime rows

### Task 7 Files

- Create: `cybros/app/services/statistics/tool_call_fact_backfill.rb`
- Test: `cybros/test/lib/cybros/statistics/tool_call_fact_backfill_test.rb`

### Task 7 / Step 1: Write the failing test

Add tests that prove:

- historical task nodes can be projected into facts
- rerunning backfill is idempotent
- missing old repair/failure details degrade to `unknown` rather than fabricated values
- sample-origin fallback defaults old runtime rows correctly

### Task 7 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/statistics/tool_call_fact_backfill_test.rb
```

Expected: FAIL because no backfill service exists.

### Task 7 / Step 3: Write minimal implementation

Implement a service that scans eligible historical `task` nodes and feeds them through the same projector logic.

Keep it:

- resumable enough for local reruns
- safe to run repeatedly
- conservative with unverifiable old rows

### Task 7 / Step 4: Run test to verify it passes

Run the same test again.

Expected: PASS

### Task 7 / Step 5: Commit

```bash
git add cybros/app/services/statistics/tool_call_fact_backfill.rb cybros/test/lib/cybros/statistics/tool_call_fact_backfill_test.rb
git commit -m "feat: add tool call fact backfill"
```

## Task 8: Add runtime-only aggregation service for reliability metrics

### Task 8 Files

- Create: `cybros/lib/cybros/statistics/tool_reliability_stats.rb`
- Test: `cybros/test/lib/cybros/statistics/tool_reliability_stats_test.rb`

### Task 8 / Step 1: Write the failing test

Add service tests that assert:

- default scope only uses `sample_origin = "runtime"`
- executable rate, first-pass success rate, repair-assisted success rate, and tool success rate are computed with the agreed denominators
- model failure counts include `invalid_args` and `tool_not_found`
- policy/approval rows are counted separately
- grouping works by model, tool, failure class, day, and execution scope

### Task 8 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/statistics/tool_reliability_stats_test.rb
```

Expected: FAIL because no aggregation service exists.

### Task 8 / Step 3: Write minimal implementation

Implement a dedicated query service that returns page-ready sections such as:

- `summary`
- `by_model_ref`
- `by_tool_name`
- `by_failure_class`
- `by_day`
- `by_execution_scope`

Do not put metric math in controllers or views.

### Task 8 / Step 4: Run test to verify it passes

Run the same test again.

Expected: PASS

### Task 8 / Step 5: Commit

```bash
git add cybros/lib/cybros/statistics/tool_reliability_stats.rb cybros/test/lib/cybros/statistics/tool_reliability_stats_test.rb
git commit -m "feat: add runtime tool reliability stats service"
```

## Task 9: Extend the `Statistics` page with runtime tool reliability sections

### Task 9 Files

- Modify: `cybros/app/controllers/statistics_controller.rb`
- Modify: `cybros/app/views/statistics/show.html.erb`
- Test: `cybros/test/integration/statistics_page_test.rb`
- Test: `cybros/test/integration/statistics_page_tool_reliability_test.rb`

### Task 9 / Step 1: Write the failing tests

Add integration coverage that proves:

- existing token usage sections still render
- runtime reliability summary cards render
- by-model, by-tool, by-failure-class, and by-day sections render from runtime facts
- non-runtime samples do not appear in the default page

### Task 9 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/integration/statistics_page_test.rb test/integration/statistics_page_tool_reliability_test.rb
```

Expected: FAIL because the page only renders token usage today.

### Task 9 / Step 3: Write minimal implementation

Update controller and view to:

- keep existing token usage stats
- add runtime tool reliability stats in clearly separated sections
- render rates and counts without burying denominator logic in the template

Preserve the established page layout and access control rules.

### Task 9 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 9 / Step 5: Commit

```bash
git add cybros/app/controllers/statistics_controller.rb cybros/app/views/statistics/show.html.erb cybros/test/integration/statistics_page_test.rb cybros/test/integration/statistics_page_tool_reliability_test.rb
git commit -m "feat: show runtime tool reliability on statistics page"
```

## Task 10: Add explicit subagent child scope accounting

### Task 10 Files

- Modify: `cybros/app/services/statistics/tool_call_fact_projector.rb`
- Modify: `cybros/lib/cybros/statistics/tool_reliability_stats.rb`
- Test: `cybros/test/models/statistics/tool_call_fact_projector_test.rb`
- Test: `cybros/test/integration/statistics_page_subagent_scope_test.rb`
- Test: `cybros/test/scenarios/dag/subagent_child_conversation_flow_test.rb`

### Task 10 / Step 1: Write the failing tests

Add coverage that proves:

- ordinary branch/thread child conversations are not mislabeled as `subagent_child`
- real subagent child conversations are labeled `subagent_child`
- parent-side `subagent_run` / `subagent_wait` rows stay in `execution_scope = "parent"`
- statistics grouping by execution scope is correct

### Task 10 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/models/statistics/tool_call_fact_projector_test.rb test/integration/statistics_page_subagent_scope_test.rb test/scenarios/dag/subagent_child_conversation_flow_test.rb
```

Expected: FAIL because subagent child scope is not yet represented in the fact layer.

### Task 10 / Step 3: Write minimal implementation

Derive `execution_scope` from explicit subagent provenance in conversation metadata rather than from generic parent/child relationships.

Expose the scope as:

- a grouped stats section
- a filterable dimension inside the aggregation service

### Task 10 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 10 / Step 5: Commit

```bash
git add cybros/app/services/statistics/tool_call_fact_projector.rb cybros/lib/cybros/statistics/tool_reliability_stats.rb cybros/test/models/statistics/tool_call_fact_projector_test.rb cybros/test/integration/statistics_page_subagent_scope_test.rb cybros/test/scenarios/dag/subagent_child_conversation_flow_test.rb
git commit -m "feat: add subagent scope to tool reliability stats"
```

## Task 11: Final docs, verification, and cleanup

### Task 11 Files

- Modify: `cybros/docs/plans/2026-03-07-model-eval-harness-design.md`
- Modify: `cybros/docs/plans/2026-03-07-model-eval-harness.md`
- Modify: `cybros/docs/agent_core/node_payloads.md`

### Task 11 / Step 1: Update docs

Update adjacent docs so they reflect the final contract:

- runtime statistics are the real-world truth for tool reliability
- eval may reuse the taxonomy later but is not part of default product metrics
- product-facing statistics services live under the `Statistics` namespace boundary
- task payload docs describe durable repair attribution and tool failure taxonomy fields

### Task 11 / Step 2: Run focused verification

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/statistics/usage_stats_test.rb test/models/statistics/tool_call_fact_test.rb test/models/conversation_statistics_origin_test.rb test/lib/agent_core/resources/tools/tool_failure_taxonomy_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/lib/cybros/statistics/tool_call_fact_backfill_test.rb test/lib/cybros/statistics/tool_reliability_stats_test.rb test/integration/statistics_page_test.rb test/integration/statistics_page_tool_reliability_test.rb test/integration/statistics_page_subagent_scope_test.rb
```

Expected: PASS

### Task 11 / Step 3: Run broader regression

Run:

```bash
cd cybros
bin/rails test test/scenarios/dag/agent_core_dag_integration_flow_test.rb test/scenarios/dag/subagent_child_conversation_flow_test.rb test/integration/conversation_subagent_activity_ui_test.rb test/models/conversation/turn_execution_subagent_activity_test.rb
```

Expected: PASS

### Task 11 / Step 4: Commit

```bash
git add cybros/docs/plans/2026-03-07-model-eval-harness-design.md cybros/docs/plans/2026-03-07-model-eval-harness.md cybros/docs/agent_core/node_payloads.md
git commit -m "docs: align eval and runtime reliability contracts"
```

Plan complete and saved to `docs/plans/2026-03-08-runtime-tool-reliability-statistics.md`. Two execution options:

1. Subagent-Driven (this session) - I dispatch fresh subagent per task, review between tasks, fast iteration
2. Parallel Session (separate) - Open new session with executing-plans, batch execution with checkpoints

Which approach?
