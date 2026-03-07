# Turn Execution Progress Design

## Summary

This design replaces the narrower "tool progress" framing with a broader execution model centered on the turn.

It supersedes the earlier March 7 tool-progress drafts.

The target shape is:

- the canonical runtime-facing object is `turn_execution`
- `turn_execution` contains typed `activities[]`
- the default chat UI still centers on the parent `agent_message` bubble
- the bubble renders a projection of assistant-owned execution, not raw scheduler internals
- composer/conversation state remains separate
- subagents remain independent conversations/graphs, but appear as first-class activities in the same execution model

This design intentionally keeps the DAG topology simple. It does not turn subagents into nested graphs inside one DAG. Instead, it introduces a projection contract that can represent same-graph tasks and cross-conversation subagents in one coherent activity model.

## Why This Replaces "Tool Progress"

The existing "tool progress" frame is now too narrow for the codebase:

- the current product already has preflight tasks (`compress_input`, `compact_context`)
- approval is already a durable execution state, not just a tool detail
- subagent MVP support already exists via `subagent_spawn` / `subagent_poll`
- `AgentRuntimeSurface` will add rewrite/projection stages that are broader than tools

So the right abstraction is no longer "what tools are running?" but:

- "what is this turn currently doing?"

## Goals

- Introduce one canonical execution contract for a turn.
- Keep durable truth in DAG nodes, node state, and node events rather than in frontend-only state.
- Let the parent assistant bubble show execution truth without becoming the source of truth.
- Support same-conversation tasks and cross-conversation subagents within one activity model.
- Keep queue/steer/composer state out of assistant-bubble execution state.
- Make behind-the-scenes execution diagnosable through durable structured activity history and replayable operator-facing reads.
- Leave room for richer runtime-surface-driven projection later without redesigning the whole contract again.

## Non-goals

- Redesign DAG topology to add nested subgraphs or cross-graph edges.
- Make every task node a transcript row by default.
- Mirror child-conversation internal realtime execution into the parent bubble in the first milestone.
- Solve every future execution UI surface now.
- Freeze every exact preview/result field before `AgentRuntimeSurface.project_tool_result` lands.
- Retain every raw intermediate diagnostic forever.

## Delivery posture

This design assumes an experimental environment where breaking changes are acceptable.

Implications:

- backward compatibility with earlier execution-progress drafts is not required
- database-preserving migrations are not required if they add unnecessary complexity
- clearing local/test data or resetting the database is acceptable when it materially simplifies the implementation

## Existing Constraints

### 1. DAG truth is already good enough

The current code already has the most important substrate:

- `task` nodes carry stable `tool_call_id`, resolved tool name, requested tool name, arguments, and argument summary
- task state is durable
- `turn_id` already groups the user message, assistant loop, and descendant tasks
- `Conversation Input Policies` already drew a clean line between assistant-bubble state and composer state

We should build on these invariants instead of introducing a second execution store first.

### 2. Subagents are already app-level, cross-conversation

Current subagent support is real but MVP-level:

- `subagent_spawn`
- `subagent_poll`
- child conversation metadata contract
- bounded transcript preview
- nested spawn protection
- ownership and UUID validation

This is enough to model subagents as execution activities, but not enough to treat them as fully managed child workers yet.

### 3. Runtime surface will change projection semantics

`AgentRuntimeSurface` introduces:

- `review_tool_call`
- `project_tool_result`
- `finalize_output`

So this design should stabilize:

- activity identity
- activity state
- turn-scoped aggregation

before it stabilizes every exact preview/result rendering rule.

## Approaches Considered

### Approach A: Keep `run_state.tools[]` and bolt subagents on later

Pros:

- smallest delta from the current plan docs
- fastest path to a tool-only UI

Cons:

- bakes the wrong shape into read APIs
- turns subagent support into an awkward special case later
- does not model approvals, preflight work, or runtime-surface stages cleanly

### Approach B: Create a second durable execution store

Pros:

- projector can become simpler
- execution queries can be purpose-built

Cons:

- duplicates DAG truth
- creates consistency/replay problems
- high migration cost for uncertain benefit

### Approach C: Recommended

Use a projector-first model:

- canonical truth stays in DAG + node events
- app reads a turn-scoped `turn_execution`
- UI consumes projections of `turn_execution`
- activities unify tools, approvals, preflight work, and subagents

This keeps the storage model simple while still giving us the right long-term contract.

## Chosen Model

### Canonical object: `turn_execution`

Suggested read shape:

```json
{
  "turn_id": "uuid",
  "anchor_node_id": "user_or_agent_node_id",
  "status": "running",
  "phase": "execution",
  "diagnostic_level": "standard",
  "event_cursor": 42,
  "started_at": "2026-03-08T00:00:00Z",
  "updated_at": "2026-03-08T00:00:05Z",
  "finished_at": null,
  "summary": {
    "activity_count": 4,
    "running_count": 2,
    "awaiting_count": 1,
    "failed_count": 0,
    "latest_message": "Waiting for subagent review_worker"
  },
  "activities": [
    {
      "activity_id": "task:uuid",
      "kind": "tool_call",
      "status": "running",
      "phase": "execution",
      "sequence": 7,
      "title": "memory_search",
      "source_node_id": "task_uuid",
      "tool_call_id": "tc_1",
      "input_preview": "{\"query\":\"...\"}",
      "output_preview": null,
      "error": null,
      "diagnostics": null,
      "started_at": "2026-03-08T00:00:01Z",
      "updated_at": "2026-03-08T00:00:05Z",
      "finished_at": null,
      "visibility": "assistant_bubble"
    }
  ]
}
```

Frozen contract notes:

- `event_cursor` is the latest durable execution event sequence/id visible to the projector for this turn. It is a replay/debug cursor, not a UI-local counter.
- `activities[]` is ordered as a concise execution timeline. The canonical ordering key is durable `sequence`; any secondary sort is only a deterministic tie-breaker for equal-sequence records and must not change activity identity.
- `diagnostic_level` changes diagnostic richness only. It must not change `activity_id`, `kind`, `status`, `phase`, `source_node_id`, or ordering.

Suggested per-activity ordering and diagnostic shape:

```json
{
  "activity_id": "task:uuid",
  "kind": "tool_call",
  "status": "failed",
  "phase": "execution",
  "sequence": 9,
  "last_event_id": 42,
  "source_node_id": "task_uuid",
  "visibility": "assistant_bubble",
  "diagnostic_level": "debug",
  "error": {
    "summary": "tool execution failed",
    "code": "tool_runtime_error"
  },
  "diagnostics": {
    "executor": "task_executor",
    "replay_gap": false
  }
}
```

### `turn_execution.status`

Recommended values:

- `pending`
- `running`
- `awaiting_approval`
- `completed`
- `failed`
- `stopped`

### `phase`

Recommended values:

- `preflight`
- `planning`
- `authorization`
- `execution`
- `finalization`
- `terminal`

Status and phase should stay orthogonal:

- `status` answers whether the turn is active, waiting, terminal, or failed
- `phase` answers which stage of execution is currently relevant

Recommended reduction rules:

- if the turn was explicitly canceled or anchor execution was stopped, use `status = "stopped"` and `phase = "terminal"`
- else if any relevant activity is actively running, use `status = "running"` and the highest-precedence active phase
- else if any relevant activity is waiting on approval, use `status = "awaiting_approval"` and `phase = "authorization"`
- else if terminal activities include failures, use `status = "failed"` and `phase = "terminal"`
- else if all relevant activities are terminal, use `status = "completed"` and `phase = "terminal"`
- else use `status = "pending"` and the earliest known phase

### `activities[*].kind`

Recommended first-pass kinds:

- `tool_call`
- `approval`
- `subagent`
- `preflight_task`

Not every surface must render every kind.

Reserved for later, not required in Milestone 1 or 2:

- `llm_step`

### `activities[*].status`

Recommended values:

- `planned`
- `pending`
- `queued`
- `running`
- `awaiting_approval`
- `completed`
- `failed`
- `rejected`
- `skipped`
- `stopped`

### `visibility`

Recommended first-pass values:

- `assistant_bubble`
- `composer_only`

Frozen behavior:

- `assistant_bubble` activities are eligible for projection into `agent_message.run_state`
- `composer_only` activities remain part of canonical `turn_execution`, but are not rendered in the assistant bubble by default
- visibility affects projection only; it does not change canonical activity identity or status reduction

Suggested example:

```json
[
  {
    "activity_id": "task:compact_context",
    "kind": "preflight_task",
    "visibility": "composer_only"
  },
  {
    "activity_id": "task:tool_1",
    "kind": "tool_call",
    "visibility": "assistant_bubble"
  }
]
```

## Projection Surfaces

### 1. `turn_execution`

Used by:

- future debug views
- richer ops views
- future DAG debug CLI consumers
- any API that wants a turn-scoped execution summary

This is the broadest app-facing read.

### 2. `agent_message.run_state`

Used by:

- the default assistant bubble
- `messages/refresh`
- reconnect/replay convergence

This is a projection of `turn_execution`, not a separate source of truth.

The assistant bubble should only include activities whose `visibility` is `assistant_bubble`.

Suggested projected shape:

```json
{
  "status": "running",
  "phase": "execution",
  "diagnostic_level": "standard",
  "event_cursor": 42,
  "summary": {
    "activity_count": 2,
    "running_count": 1,
    "awaiting_count": 0,
    "failed_count": 0,
    "latest_message": "Running memory_search"
  },
  "activities": [
    {
      "activity_id": "task:uuid",
      "kind": "tool_call",
      "status": "running",
      "phase": "execution",
      "sequence": 7,
      "title": "memory_search",
      "source_node_id": "task_uuid",
      "visibility": "assistant_bubble"
    }
  ]
}
```

### 3. `composer_state`

Still used by:

- queue rail
- steer hints
- candidate next input
- pre-send product guidance

This remains intentionally separate from assistant-bubble execution state.

## Frozen Scope Boundaries

### Same-turn projector scope

The projector scope is intentionally narrow:

- project only nodes that belong to the same conversation and the same `turn_id`
- treat same-turn descendant task/activity facts as the canonical input set for Milestone 1
- do not merge multiple turns into one `turn_execution`
- do not make assistant-bubble projection depend on prior cable delivery or client-local aggregation

This keeps `turn_execution` rebuildable from durable truth and prevents bubble state from drifting from DAG truth.

## Activity Mapping

### Tool calls

Canonical source:

- descendant `task` nodes in the same `turn_id`
- task-side input (`tool_call_id`, requested/resolved name, arguments summary)
- task state
- task result preview
- task lifecycle node events

Projection:

- `kind = "tool_call"`
- `source_node_id = task.id`

### Approval

Canonical source:

- task nodes in `awaiting_approval`
- approval metadata on task nodes

Projection:

- `kind = "approval"`
- often attached to the same task node as the tool call
- may be rendered as a separate activity or folded into the tool-call activity

Implementation note:

- first milestone may fold approval into the tool-call activity for simplicity
- the canonical contract should still leave room for a separate activity later

### Preflight tasks

Canonical source:

- `compress_input`
- `compact_context`
- any future app-level turn preflight task

Projection:

- `kind = "preflight_task"`
- `visibility = "composer_only"` by default

They belong in `turn_execution`, but not in the assistant bubble by default.

### Subagents

Canonical source:

- parent-side task/tool nodes such as `subagent_spawn`, `subagent_poll`, future `subagent_run`, future `subagent_wait`
- child conversation metadata reference
- child status snapshot returned by subagent tools

Projection:

- `kind = "subagent"`
- `source_node_id = parent task node`
- `links.child_conversation_id = ...`
- title/name comes from subagent metadata or tool args

Important boundary:

- the child conversation remains a separate graph
- v1 does not mirror the child's internal task list into the parent
- parent-visible subagent state comes from parent-side orchestration facts and child snapshots only
- Milestone 1 parent-side `subagent_spawn` / `subagent_poll` remain ordinary task activities
- Milestone 2 may project `subagent_run` / `subagent_wait` as `kind = "subagent"`, but still only from parent-visible orchestration facts

## Event Contract

The current generic `progress/log` event kinds should stop being the primary execution-progress contract.

Recommended new kinds:

- `activity_planned`
- `activity_started`
- `activity_updated`
- `activity_waiting`
- `activity_finished`
- `activity_failed`
- optional `turn_execution_snapshot`

Each event should include:

- `event_id`
- `turn_id`
- monotonic `sequence`
- `activity_id`
- `kind`
- `status`
- `phase`
- `source_node_id`
- `diagnostic_level`
- typed payload

`output_delta` may still exist for streamed assistant text.

So the split becomes:

- assistant text streaming: `output_delta`
- execution progress: structured `activity_*`

## Replay and Refresh Rules

The contract must satisfy:

- refresh without prior cable history
- reconnect after missed events
- replay after partial delivery
- terminal convergence after Turbo replace

That implies:

- `Conversation#turn_execution_for(...)` must rebuild current execution state from durable truth alone
- `Conversation#message_for_node_id(...)` must be able to project `run_state` from that turn execution
- cable events are acceleration only

## Observability, Diagnostics, and Retention

These flows are mostly behind the scenes, so manual product testing will not be enough.

`turn_execution` should therefore serve two roles at once:

- the canonical execution read model for product rendering
- the concise execution log surface for operators and debugging

That operator-facing log surface should stay consumer-agnostic:

- assistant bubble projection is one consumer
- internal debug views are another
- DAG debug CLI tooling can be another

The contract should not hide diagnostics exclusively behind bubble-specific rendering rules.

### Always-on baseline observability

Every turn should always retain enough structured truth to answer:

- what activities existed
- what order they ran in
- which one failed, waited, or stopped
- which child conversation or approval gate was involved
- whether replay missed events or history was compacted later

So the baseline contract should include:

- `turn_execution.event_cursor`
- per-activity `sequence`
- stable correlation fields (`turn_id`, `source_node_id`, tool call id, child ids)
- durable status-transition timestamps
- bounded error summaries and terminal reasons

### Debug mode

The system should support an explicit diagnostic mode with at least:

- `standard`
- `debug`

Recommended shape:

- diagnostic level is turn-scoped, not UI-scoped
- the canonical flag should live on turn-owned durable metadata such as the anchor agent node
- it may be mirrored into `ConversationRun.debug` for operational bookkeeping, but projector truth should not depend only on that mirror
- `standard` remains lean and safe for routine traffic
- `debug` captures richer diagnostics for hard-to-reproduce failures

Debug mode must remain observation-only.

Invariants:

- enabling `debug` must not change canonical activity identity or status reduction
- `activity_id`, `kind`, `status`, `phase`, `source_node_id`, and ordering must stay the same between `standard` and `debug`
- `debug` may add diagnostic fields or extra bounded records, but must not introduce a second execution path
- `debug` must not widen tool permissions, subagent permissions, or other execution authority
- `debug` must not change business flow, scheduling decisions, or final execution outcomes

Initial activation can remain internal-only in the first milestone:

- explicit request/controller param
- console/admin mutation
- test fixture setup

No end-user-visible debug toggle is required in the first milestone.

Frozen invariant:

- `standard` and `debug` must project the same canonical activity identity and ordering for the same turn
- `debug` may expose richer bounded diagnostics, but it is still observation-only and must not alter permissions, scheduling, or business flow

Debug-mode-only content may include:

- executor timing details
- retry / repair decisions
- richer child snapshot payloads
- replay cursor and gap diagnostics
- truncated raw-ish payload previews when useful for diagnosis

### Retention and cleanup policy

Because `turn_execution` also serves as the historical log surface, retention must still be deliberate, but it does not need to be fully implemented in the first execution-progress rollout.

Key architectural constraint:

- deleting or compacting completed-turn execution diagnostics must not break DAG truth or runtime correctness
- loss of old `turn_execution` history should only affect display, export, and auditing depth

So the contract should stay cleanup-safe:

- active turns remain lossless
- completed turns can be removed or compacted later by app-level policy
- debug-only diagnostics are the first candidate for expiry
- baseline terminal summaries should survive longer than debug detail when policy is eventually added

Exact cleanup policy is intentionally deferred:

- exact TTL values are not part of the contract
- a later app-level cleanup policy such as deleting completed execution diagnostics older than 30 days is acceptable
- this does not need to be implemented in the first pass

## Testing and Failure Injection

Because these execution flows are hard to validate manually, implementation is not complete without strong automated coverage.

Required coverage should include:

- projector unit tests for status reduction, visibility, and ordering
- channel/integration tests for replay, refresh, reconnect, and missed-event recovery
- scenario tests for tool failure, approval wait, interruption, retry, and stale-turn behavior
- subagent tests for timeout, ownership rejection, and child status projection
- debug-mode tests proving `standard` and `debug` produce different diagnostic detail levels
- debug-mode tests proving `standard` and `debug` keep the same canonical activity identity and status reduction
- debug export tests proving diagnostic data can be inspected outside the assistant bubble

Where possible, tests should inject failure conditions directly instead of waiting for flaky emergent reproduction.

## Non-blocking Operational Choices

These choices still need to be made during implementation, but they do not change the core contract:

- exact cleanup windows / TTL values for baseline vs debug diagnostics
- the later app-level cleanup policy for completed execution diagnostics

The first direct consumer should be:

- an internal export surface for `turn_execution`
- wired into the existing DAG debug CLI
- with fuller Web UI debugging deferred until later

The important constraint is that the canonical `turn_execution` contract stays reusable across all of them.

## Recommended Subagent Strategy

### Decision

Keep subagents as independent conversations/graphs.

### Why

- avoids DAG bloat
- preserves bounded transcript/context APIs
- preserves separate audit surfaces
- keeps retries, pagination, and later compression simpler

### Additional recommendation

Before exposing richer child execution progress, formalize the worker model:

- tighten `subagent` into a genuinely minimal worker profile
- add higher-level orchestration primitives:
  - `subagent_run`
  - `subagent_wait`
  - later `subagent_cancel`

These are better parent-facing activity anchors than raw `spawn/poll` alone.

## Milestone Shape

### Milestone 1

- add `turn_execution`
- add `activities[]`
- project `agent_message.run_state`
- support same-turn tool/approval activities
- add baseline observability, event sequencing, and debug-mode-aware projection
- let parent-side subagent-related calls appear in the execution timeline as ordinary task activities
- do not mirror child internals
- keep `turn_execution` directly consumable by debug tooling outside the assistant bubble

### Milestone 2

- harden subagent worker profile
- add `subagent_run` / `subagent_wait`
- add dedicated parent-visible `kind = "subagent"` activity snapshots
- keep child execution as a separate conversation/graph and avoid merging child DAG internals into the parent

### Milestone 3

- add an app-level cleanup policy for historical execution diagnostics if needed
- consider child execution mirroring or bridged snapshots
- consider separate developer execution timeline

## Risks

- A turn-scoped projector is conceptually bigger than the original tool-only plan.
- If activity kinds are allowed to proliferate too early, the UI will collapse into noise.
- Runtime-surface work may still force changes in preview/result semantics.
- Subagent progress can sprawl into orchestration work if Milestone 1 and 2 are not kept separate.
- Diagnostic payloads can grow quickly unless debug mode and later cleanup policy stay disciplined.

## Recommended Decision

Build the next iteration around:

- `turn_execution`
- `activities[]`
- assistant-bubble projection over that execution
- independent child conversations for subagents
- explicit observability and debug mode from day one
- cleanup-safe historical execution data, with automatic cleanup policy deferred

This is the cleanest path that solves today's tool progress problem without painting the product into a corner once subagents become first-class.
