# Append Task Internal Queue Design

## Status

Design notes for refactoring programmable-agent `create_task(append)` away from immediate DAG materialization and toward a durable turn-internal queue.

This document is written against the latest code reality on March 12, 2026, including the newly added bootstrap hooks:

- `on_conversation_created`
- `on_lane_first_user_message`
- `before_agent_step`
- `on_context_pressure`
- `before_subagent_spawn`
- `before_finalize_output`
- `after_task_notice`
- `after_subagent_result`

## Problem

Current `create_task(append)` behavior still materializes DAG task nodes immediately inside `Cybros::ProgrammableAgent::HookActionExecutor`.

That is workable, but it leaves several problems unsolved:

- append follow-up work has no durable staging layer inside a turn
- turn reset and task retry do not have a first-class place to reason about append work independently from already-materialized DAG nodes
- automatic parallel fanout for task families such as `subagent_run` has no clean scheduler boundary
- `append` orchestration is forced to rewrite the DAG immediately even when the intent is simply "do this later in the same turn"

The existing queues in the system are not the right abstraction for this:

- user queue is next-turn user input staging
- execution-target queue is runtime-capacity backpressure
- `RunDraft` is planning-time durable state

The missing abstraction is a turn-owned durable execution queue for agent-authored append work.

## Goals

- make `create_task(append)` durable before it becomes a DAG node
- keep `RunDraft` scoped to planning rather than execution follow-up
- keep DAG nodes as execution truth after materialization
- allow FIFO queue ordering without requiring strictly serial execution
- support metadata-declared automatic parallelization for safe task families
- make turn reset and single-task retry semantically distinct
- keep user queue and internal queue completely separate

## Non-Goals

- no change to `create_task(prepend)` in V1
- no generic queue editing or deletion API
- no user-visible editing or cancellation of internal queue rows
- no priority system in V1
- no arbitrary dependency graph between queued tasks in V1
- no reuse of `RunDraft` as the storage model for internal queued tasks

## Latest Runtime Context

Latest code already establishes two relevant facts:

1. bootstrap hooks now exist, but not all hooks are equally turn-scoped
2. append-only bootstrap behavior already exists for reserved `cybros_*` tasks

This design therefore distinguishes two categories:

### Turn-scoped append hooks

These may enqueue into the new internal queue because they are attached to a concrete turn:

- `on_lane_first_user_message`
- `on_context_pressure` when it emits `create_task(append)`
- `after_task_notice`
- `after_subagent_result`
- `before_finalize_output`

### Non-turn-scoped bootstrap hooks

These do **not** use the new queue in V1 because there is no real turn yet:

- `on_conversation_created`

`on_conversation_created` should continue to materialize bootstrap authority work through its own conversation-bootstrap path until a separate non-turn queue is explicitly designed.

## Core Decision

Add a new first-class durable turn-internal queue for append work.

The model should be:

- `create_task(prepend)`:
  - immediate DAG rewrite / defer semantics
  - unchanged in V1
- `create_task(append)`:
  - immediate admission into a durable turn-owned queue
  - later materialization into DAG task nodes by a scheduler

This preserves the existing boundary:

- planning belongs to `RunDraft`
- queued append work belongs to a turn-owned execution queue
- materialized execution belongs to the DAG

## Why Not "Everything Starts As Draft"

Do **not** generalize `RunDraft` into a universal pre-node state.

That would re-couple:

- planning durability
- runtime follow-up orchestration
- DAG execution truth

The cleaner split is:

- `RunDraft` for turn planning before execution exists
- internal queue for turn-owned append orchestration after planning
- DAG for materialized execution

## Data Model

Introduce a new durable table, tentatively named:

- `turn_internal_tasks`

Each row represents one append work item that has not yet fully completed.

Suggested fields:

- `id`
- `conversation_id`
- `graph_id`
- `lane_id`
- `turn_id`
- `source_node_id`
- `source_hook_name`
- `source_notice_id` or equivalent source fingerprint
- `logical_tool_name`
- `input`
- `authored_metadata`
- `tool_surface_id`
- `capability_registry_snapshot_id`
- `execution_mode`
- `queue_position`
- `status`
- `materialized_task_node_id`
- `superseded_by_id`
- `canceled_reason`
- timestamps

### `status`

V1 should support at least:

- `queued`
- `materializing`
- `materialized`
- `running`
- `finished`
- `canceled`
- `superseded`
- `failed_materialization`

### `execution_mode`

V1 should avoid a generic priority system and instead freeze the queue-time execution policy on the row itself.

Suggested values:

- `serial`
- `parallel_safe`

This is copied from the validated tool surface / routed metadata at enqueue time.
Materialization should not consult live tool surface state later.

## Admission Rules

`create_task(append)` should become:

1. validate hook policy
2. validate routing against the current tool surface
3. freeze routing metadata needed for later materialization
4. enqueue a durable internal task row

This is immediate enqueue, not a second planning phase.

Kernel admission still validates:

- hook is allowed to append
- `logical_tool_name` is allowed on the current tool surface
- payload schema is valid
- turn/lane anchor is valid
- queue bounds are not exceeded

## Idempotency

Append enqueue must be source-idempotent.

Suggested idempotency basis:

- `turn_id`
- `source_node_id`
- `source_hook_name`
- `action_index`
- optional `source_notice_fingerprint`

This prevents duplicate append rows when the same source notice or hook result is replayed.

## Materialization Scheduler

Queue ordering and execution concurrency should be explicitly separate.

### Ordering

- strict FIFO by `queue_position`
- FIFO ordering and serial barriers are evaluated per turn, not graph-global
- one turn's active serial row must not block another turn's queue head

### Execution

- scheduler scans the queue from the head
- it may materialize a safe prefix in parallel
- it must stop at the first serial barrier

V1 algorithm:

1. read `queued` rows in FIFO order
2. if the first row is `serial`, materialize only that row
3. if the first row is `parallel_safe`, keep taking rows while they remain `parallel_safe`
4. stop at the first `serial` row after that prefix
5. mark selected rows `materializing`
6. create DAG task nodes
7. backfill `materialized_task_node_id`

This gives:

- FIFO queue semantics
- safe automatic fanout
- turn-local blocking rather than graph-wide head-of-line blocking
- no need for explicit parallel batch actions in V1

## Parallelism Declaration

Parallelism should not be a hook-authored ad hoc decision.

The declaration should come from tool surface / tool metadata.

Recommended V1 shape:

- `execution_mode: "serial" | "parallel_safe"`

This keeps the concurrency policy:

- auditable
- validated
- route-aware
- frozen at queue-admission time

The first natural V1 task family to mark `parallel_safe` is:

- `subagent_run`

## Retry And Reset Semantics

### Single-task retry

- retry applies to one materialized task
- internal queue rows remain intact
- pre-task hooks are not replayed for the whole turn
- source-idempotent append rows are therefore stable

### Turn reset

Turn reset means:

- keep the turn head
- keep the user-authored turn input
- clear all execution-derivative state for that turn

That includes:

- queued internal rows
- materialized DAG tasks derived from that queue
- continuation nodes
- placeholder/follow-up nodes
- subgraphs derived from that turn's execution

Implementation should prefer status transitions over physical deletion:

- queue rows -> `canceled` / `reset`
- DAG nodes -> stopped/canceled/reset-style terminal states with provenance

The reset boundary should be:

- turn input is preserved as intent
- everything else is treated as execution derivative

## Queue Mutation Policy

V1 should **not** support generic queue editing.

The policy should be:

- queue rows are immutable once created
- users cannot edit or cancel them
- agent code cannot directly mutate them in place

Future evolution may add:

- `cancel queued task`
- `supersede queued task`

But even then:

- no in-place payload edits
- no physical deletes

`cancel` / `supersede` should be modeled as additional durable state transitions.

## Relationship To Bootstrap Hooks

Latest runtime additions affect scope:

### `on_lane_first_user_message`

This hook is lane- and turn-sensitive.
It is a valid future producer for turn-internal append queue rows.

Its current append-only `cybros_*` authority tasks should therefore be compatible with this design.

### `on_conversation_created`

This hook is not turn-scoped.
It should remain outside this design in V1.

If Cybros later wants a durable non-turn bootstrap queue, that should be designed as a separate abstraction rather than overloading the turn-internal queue.

## Acceptance Scenarios

The most representative validation scenarios for this refactor come from the newly added
`on_lane_first_user_message` hook family, because they exercise append-only orchestration
without relying on a live assistant placeholder.

### Scenario A: Main-lane first user message generates the conversation title

Current bundled/default behavior already appends `cybros_generate_title` from
`on_lane_first_user_message`.

After this refactor, the canonical behavior should be:

- the hook still returns append-only authority tasks
- the append action creates a durable turn-internal queue row rather than an immediate DAG task
- the queue row later materializes into a DAG task
- the authority task updates `conversation.title`
- the first assistant reply path remains independent from title generation

This is the cleanest conversation-scoped validation scenario because it proves:

- turn-scoped append work can be durable without becoming planning state
- conversation-level product mutation still happens through Cybros-owned execution
- bootstrap/authority behavior remains replay-safe and auditable

### Scenario B: Branch-lane first user message enqueues branch summary follow-up

Current bundled/default behavior appends both:

- `cybros_generate_title`
- `cybros_enqueue_lane_summary`

for branch lanes.

After this refactor, the canonical behavior should be:

- both append actions become durable turn-internal queue rows
- FIFO ordering remains stable
- branch-lane summary follow-up stays lane-scoped rather than conversation-scoped
- summary work can later participate in queue scheduling without bypassing the DAG

This is the cleanest lane-scoped validation scenario because it proves:

- queue-backed append work can carry multiple follow-up items from one hook result
- lane-local durable context work stays distinct from conversation-level state mutation
- future `parallel_safe` scheduling can be added without changing hook semantics

### Scenario C: `on_conversation_created` stays outside the turn queue

`on_conversation_created` is intentionally the control case.

It should continue to materialize bootstrap authority work through its existing
conversation-bootstrap path rather than entering the turn-internal queue.

That contrast is important because it proves the queue boundary is genuinely turn-scoped:

- conversation bootstrap remains outside the queue
- lane-first-user append work enters the queue
- the runtime does not blur conversation bootstrap and turn execution

## V1 Scope

V1 should do only this:

- introduce durable turn-internal append queue rows
- refactor turn-scoped `create_task(append)` to enqueue rather than materialize
- keep `prepend` unchanged
- keep FIFO ordering
- allow metadata-declared `parallel_safe` fanout
- start with `subagent_run` as the first `parallel_safe` task family

V1 should explicitly not do:

- queue priority
- editable queue rows
- non-turn bootstrap queue
- arbitrary inter-queue dependencies
- append queue cross-turn survival

## Testing Expectations

The implementation plan should prove at least:

- append tasks enqueue durable rows instead of immediate DAG nodes
- main-lane `on_lane_first_user_message` title generation enters the turn queue rather than directly mutating the DAG
- branch-lane `on_lane_first_user_message` summary follow-up enters the turn queue rather than directly mutating the DAG
- `on_conversation_created` remains outside the turn queue
- FIFO queue ordering is stable
- `parallel_safe` subagent fanout materializes as a safe prefix
- single-task retry preserves queue rows
- turn reset cancels queued rows and clears turn-derived execution nodes while preserving turn input
- replay of the same hook/notice does not duplicate queued append work
- title generation remains conversation-scoped while lane summary follow-up remains lane-scoped

## Recommendation

Proceed with a narrow refactor:

- turn-scoped append work becomes queue-backed
- queue is durable and FIFO
- concurrency is derived from validated metadata
- reset and retry semantics are explicit

This gives Cybros a proper orchestration layer for append work without collapsing:

- user queue
- planning draft
- execution queue
- DAG truth

into one overloaded abstraction.
