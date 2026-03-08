# Runtime Tool Reliability Statistics Design

## Summary

This design adds a runtime-native tool reliability statistics system for Cybros.

The target shape is:

- the `Statistics` page remains the primary product surface
- the default dataset is **real runtime traffic only**
- the canonical unit is one durable fact row per `task` node that represents a tool call attempt
- product-facing statistics services converge under a `Statistics` naming boundary instead of being split across `LLM` and other namespaces
- model-side tool-calling quality and tool-side execution quality are tracked separately
- subagent child conversations remain independent graphs, but their child tool calls are included in the same statistics model with an explicit scope marker
- the future eval harness may reuse the same taxonomy, but eval samples are not part of default product statistics

This design intentionally does not use channel replay, UI projection state, or debug-only views as the source of truth. The statistics system must be derived from durable runtime facts that survive refresh, reconnect, replay, and backfill.

## Status

This document should be treated as an approved architecture direction for runtime tool reliability metrics.

Recommended sequencing:

1. freeze the runtime-only sample boundary and metric taxonomy
2. add durable per-task facts and failure classification
3. project historical and new runtime tool calls into a statistics fact table
4. extend `Statistics` to query the fact table instead of trying to derive reliability directly from DAG JSON
5. let eval harness reuse the same taxonomy later without changing the product-default runtime view

## Goals

- Measure real-world model tool-calling quality from runtime traffic.
- Measure real-world tool execution quality separately from model quality.
- Define one canonical statistics fact per tool call attempt.
- Keep the source of truth durable and backfillable from runtime state.
- Preserve correct subagent accounting without collapsing child graphs into the parent DAG.
- Add a stable failure taxonomy that is broad enough for dashboards and drill-down, but not provider-specific by default.
- Make the `Statistics` page useful for both product-level monitoring and engineering diagnosis.

## Non-goals

- Replace the existing token usage statistics; those remain useful and should coexist.
- Rename the `/statistics` route or redesign the `StatisticsController` surface.
- Treat `turn_execution` or `run_state` as the canonical statistics source.
- Count `policy_denied` or `awaiting_approval` as model tool-calling failures.
- Merge subagent child DAGs into parent DAG execution truth.
- Build judge-based model evaluation or subjective quality scoring here.
- Make provider-specific failure codes the primary dashboard taxonomy in the first pass.
- Depend on ActionCable delivery, debug mode, or operator scripts to construct statistics.

## Why Runtime Statistics Must Be Canonical

The existing plan for model evaluation is still useful, but it is not the most accurate view of production reality.

Eval harness runs:

- are curated
- are development-driven
- can over-represent idealized prompts
- do not reflect real user approval paths, retries, or external dependency flakiness

Runtime statistics, by contrast, observe:

- the actual model selected for a real turn
- the actual tool call emitted by the model
- the real policy/approval outcome
- the actual tool execution result
- the real remote failure mode when a dependency breaks

That makes runtime statistics the better truth for:

- model tool-calling success rate
- repair-assisted success rate
- real tool reliability
- failure distribution by tool, model, and time

Eval should eventually reuse the same taxonomy, not define a different one.

## Existing Context

### 1. The `Statistics` page already exists

Today `GET /statistics` is backed by token usage aggregation:

- `Cybros::LLM::UsageStats`
- `StatisticsController`
- `app/views/statistics/show.html.erb`

That means there is already a product surface to carry runtime metrics. We do not need a new page or a second dashboard area.

However, the current namespace split is not ideal:

- token usage lives under `Cybros::LLM`
- future reliability metrics would otherwise live under `Statistics`

That would leave one product page backed by two unrelated naming domains. This design treats that as a cleanup target, not as a compatibility constraint.

### 2. Runtime tool execution already has durable truth

The current runtime already persists most of the raw material needed for statistics:

- `task.body.input`
  - `tool_call_id`
  - `requested_name`
  - `name`
  - `name_resolution`
  - `arguments`
  - `source`
- `task.state`
- `task.started_at` / `task.finished_at`
- `task.body.output.result`
- `agent_message.metadata.tool_loop.*`
  - tool name repair
  - tool args repair
  - invalid schema args
- conversation/subagent metadata

This is enough to build a canonical statistics read model without inventing a second execution engine.

### 3. Turn execution is the wrong abstraction for final statistics storage

`turn_execution` is the right abstraction for UI execution state, but not for long-lived reliability analytics:

- it is turn-scoped rather than tool-call-scoped
- it intentionally projects UI-friendly activity summaries
- it may hide composer-only activities
- it is optimized for replay/refresh correctness, not for statistics aggregation

Statistics should use turn execution concepts only where they help naming or correlation, not as the source of truth.

### 4. Current repair metadata is still too aggregate

Today the repair loops store turn-level aggregate metadata like:

- `tool_loop.repair.repaired`
- `tool_loop.tool_name_repair.repaired`

That is not enough to classify each task row precisely as:

- first-pass executable
- repaired-name executable
- repaired-args executable
- repaired-both executable

We need per-task durable attribution.

## Approaches Considered

### Approach A: Query reliability directly from `dag_nodes` JSON on every page load

Pros:

- fastest initial implementation
- no new table

Cons:

- metric logic gets spread across SQL fragments and view helpers
- backfill and contract changes become painful
- `first-pass` vs `repair-assisted` attribution is awkward
- expensive and brittle once the page needs more slices

### Approach B: Recommended

Add a canonical statistics fact table with one row per runtime tool call attempt.

Pros:

- stable contract
- cheap to query
- backfillable
- separates runtime truth extraction from UI aggregation
- cleanly supports subagent child scope, approval side states, and future eval reuse

Cons:

- adds a table and projector
- requires explicit failure taxonomy and sample-origin rules

### Approach C: Skip facts and only write daily rollups

Pros:

- very cheap dashboard queries

Cons:

- poor drill-down
- hard to repair if taxonomy changes
- backfill gets more complex
- not suitable for engineering diagnosis

## Chosen Direction

Choose **Approach B**.

The canonical storage unit is a durable statistics fact row per tool call attempt, derived from a `task` node and its upstream same-turn agent node.

Recommended model and table:

- `Statistics::ToolCallFact`
- `statistics_tool_call_facts`

Recommended query service:

- `Cybros::Statistics::ToolReliabilityStats`
- `Cybros::Statistics::UsageStats`

Recommended projector:

- `Statistics::ToolCallFactProjector`

Recommended namespace boundary:

- `Statistics::...`
  - ActiveRecord models / durable fact rows
- `Cybros::Statistics::...`
  - product-facing aggregation and query services
- `StatisticsController`
  - remains the app controller for `/statistics`, but only orchestrates `Cybros::Statistics::*`

Recommended cleanup boundary:

- migrate product token usage reads from `Cybros::LLM::UsageStats` to `Cybros::Statistics::UsageStats`
- keep `DAG::UsageStats` only as an engine/debug-scoped utility rather than a product page dependency
- do not preserve the old namespace just for compatibility if the refactor is cleaner without it

## Canonical Sample Boundary

### Default dataset

The default `Statistics` page must filter to:

- `sample_origin = "runtime"`

This is the product-default truth.

### Explicitly excluded from default product metrics

- eval harness runs
- debug CLI synthetic runs
- replay-only operator flows
- fixture/seed imports
- future offline analysis jobs

These may still write facts later, but they must be explicitly tagged with a non-runtime sample origin.

### Sample origin storage

Recommended source of truth:

- `root_conversation.metadata["statistics"]["sample_origin"]`

Rules:

- regular app user/runtime entrypoints default to `"runtime"`
- non-runtime entrypoints must explicitly set another origin
- backfill treats missing origin as `"runtime"` for pre-feature historical rows unless a known non-runtime marker says otherwise

Recommended initial origins:

- `runtime`
- `eval`
- `debug`
- `replay`

## Canonical Fact Shape

One row represents one tool call attempt as expanded into a `task` node.

Suggested shape:

```json
{
  "task_node_id": "uuid",
  "retry_of_task_node_id": null,
  "conversation_id": "uuid",
  "root_conversation_id": "uuid",
  "user_id": "uuid",
  "graph_id": "uuid",
  "turn_id": "uuid",
  "sample_origin": "runtime",
  "execution_scope": "parent",
  "tool_call_id": "tc_1",
  "requested_name": "skills.list",
  "resolved_name": "skills_list",
  "name_resolution": "alias",
  "arguments_resolution": "original",
  "model_attempt_class": "first_pass",
  "source": "skills",
  "provider_key": "openai",
  "model_ref": "openai/gpt-5.4",
  "execution_readiness": "executable",
  "entered_execution": true,
  "tool_outcome": "success",
  "failure_class": null,
  "failure_code": null,
  "retryable": null,
  "manual_retry": false,
  "started_at": "2026-03-08T10:00:01Z",
  "finished_at": "2026-03-08T10:00:02Z",
  "duration_ms": 912
}
```

### Row identity

- one `task_node_id` maps to one fact row
- retries created by `retry_of_id` become new fact rows
- upserts must be idempotent by `task_node_id`

### Excluded task kinds

Do not emit fact rows for:

- `preflight_task`
- non-tool transcript nodes

This statistics system is about tool reliability, not generic execution activity counts.

## Frozen Runtime Taxonomy

### `execution_scope`

Recommended values:

- `parent`
- `subagent_child`

Rules:

- `subagent_child` is only for conversations whose metadata contains a real subagent provenance block, not every child conversation
- branch/thread conversations must not be mislabeled as subagent traffic

### `model_attempt_class`

Recommended values:

- `first_pass`
- `repaired_name`
- `repaired_args`
- `repaired_both`

Rules:

- repair loops do not create extra statistics rows
- automatic tool name repair and tool args repair are modeled as attribution on the final task row
- manual user rerun does not change `model_attempt_class`; it creates a new fact row with `manual_retry = true`

### `execution_readiness`

Recommended values:

- `executable`
- `invalid_args`
- `tool_not_found`
- `policy_denied`
- `awaiting_approval`
- `approval_rejected`

Rules:

- `invalid_args` and `tool_not_found` count as model-side failures
- `policy_denied`, `awaiting_approval`, and `approval_rejected` are side outcomes and must be shown separately, not folded into model failure rate

### `tool_outcome`

Recommended values:

- `success`
- `failed`
- `not_executed`

Rules:

- `tool_outcome = "not_executed"` whenever `execution_readiness != "executable"`
- tool reliability metrics only use rows with `entered_execution = true`

### `failure_class`

Stable first-pass taxonomy:

- `validation_error`
- `implementation_error`
- `remote_api_error`
- `timeout`
- `rate_limit`
- `auth`
- `unknown`

This is intentionally broader than provider-specific error codes.

### `failure_code`

Optional, implementation-specific string for drill-down.

Examples:

- `tool_not_in_profile`
- `mcp_transport_error`
- `http_500`
- `openai_429`

Dashboard aggregations should not depend on `failure_code` stability.

## Durable Sources and Precedence

The projector must read from these sources, in this order of trust:

1. `task` node durable fields
   - `state`
   - `retry_of_id`
   - timestamps
2. `task.body.input`
   - requested/resolved tool identity
   - source
   - repair attribution fields
3. `task.body.output`
   - projected/raw tool result
4. `ToolResult.metadata["tool_execution"]`
   - failure classification
   - retryability
   - provider/tool-specific failure code
5. same-turn upstream `agent_message` node
   - `provider_key`
   - `model_ref`
   - tool-loop repair metadata
6. conversation/root conversation metadata
   - sample origin
   - subagent provenance

The statistics projector must **not** derive truth from:

- `turn_execution`
- `agent_message.run_state`
- ActionCable replay
- debug-only diagnostics

## Required Durable Additions

To make per-task facts correct, the runtime should freeze these additional durable fields on task expansion:

### `task.body.input["arguments_resolution"]`

Recommended values:

- `original`
- `repaired`
- `invalid`

### `task.body.input["repair"]`

Suggested shape:

```json
{
  "tool_name": true,
  "arguments": false
}
```

This is the missing link between turn-level repair counts and per-task attribution.

### `ToolResult.metadata["tool_execution"]`

Suggested shape:

```json
{
  "failure_class": "remote_api_error",
  "failure_code": "mcp_transport_error",
  "retryable": true
}
```

This is the canonical place for tool/runtime failure classification.

## Subagent Boundary

Subagents remain independent conversations and graphs.

Statistics rules:

- parent-side `subagent_run` / `subagent_wait` wrapper tasks count as ordinary tool-call facts in the parent conversation
- child-internal tool calls count as their own facts inside the child conversation
- child facts inherit `root_conversation_id` from the root conversation tree
- child facts set `execution_scope = "subagent_child"`
- no child DAG is merged into the parent DAG

This keeps tool reliability accounting accurate without breaking the independent-subagent architecture.

## Query Semantics

The `Statistics` page should query aggregated facts rather than raw DAG nodes.

Recommended metrics:

- `Executable rate`
  - rows with `execution_readiness = "executable"` / all tool-call facts
- `First-pass success rate`
  - `model_attempt_class = "first_pass"` and `tool_outcome = "success"` / all tool-call facts
- `Repair-assisted success rate`
  - repaired classes and `tool_outcome = "success"` / all tool-call facts
- `Tool success rate`
  - `tool_outcome = "success"` / rows with `entered_execution = true`

Recommended side metrics:

- `invalid_args`
- `tool_not_found`
- `policy_denied`
- `awaiting_approval`
- `approval_rejected`

Recommended slices:

- by `model_ref`
- by `resolved_name`
- by `failure_class`
- by day
- by `execution_scope`

## Statistics Page Shape

The existing page should keep token usage and add a second reliability area.

Recommended sections:

- top summary cards
  - executable rate
  - first-pass success rate
  - repair-assisted success rate
  - tool success rate
  - approval/policy side counts
- by model
- by tool
- by failure class
- by day

The page default must be runtime-only without showing eval data.

The page architecture should also be internally consistent:

- token usage sections should be served by `Cybros::Statistics::UsageStats`
- reliability sections should be served by `Cybros::Statistics::ToolReliabilityStats`
- no product page statistics logic should remain under `Cybros::LLM`

## Relation To Eval Harness

The eval harness should eventually use the same:

- `model_attempt_class`
- `execution_readiness`
- `tool_outcome`
- `failure_class`

But the product page must continue to default to:

- `sample_origin = "runtime"`

This lets runtime statistics stay accurate for real operations while still allowing later comparison with curated eval results.

## Edge Cases

### 1. Approval paths

- `awaiting_approval` is a side state, not a model failure
- `approval_rejected` is a side terminal outcome, not a model failure

### 2. Manual retry

- each manual retry is a new fact row
- the old failed row remains
- `manual_retry = true` marks the new row
- manual retry success must not inflate repair-assisted success

### 3. Runtime projection does not change statistics truth

- redacted or summarized projected output does not change whether the tool succeeded
- debug mode must not change any fact identity or classification

### 4. Backfill correctness

Historical rows may be missing explicit repair attribution or failure classification.

Backfill should:

- fill what can be derived with high confidence
- use `unknown` when classification is not recoverable
- avoid fabricating provider-specific detail

## Testing Requirements

Minimum coverage should include:

- per-task repair attribution
- failure taxonomy mapping
- policy/approval side outcomes
- runtime-only origin filtering
- subagent child scope accounting
- manual retry accounting
- statistics page rendering and aggregation
- backfill idempotency

## Acceptance Criteria

This design is satisfied only when:

- the default `Statistics` page reads runtime-only tool reliability metrics from a canonical fact table
- product-facing statistics services are organized under a coherent `Statistics` naming boundary
- model-side and tool-side success rates are clearly separated
- `invalid_args` and `tool_not_found` count as model failures
- `policy_denied` and approval states are shown separately, not counted as model failures
- subagent child tool calls are included with an explicit scope marker
- failure classes use the stable first-pass taxonomy
- the design remains compatible with future eval reuse without mixing eval into runtime-default product metrics
