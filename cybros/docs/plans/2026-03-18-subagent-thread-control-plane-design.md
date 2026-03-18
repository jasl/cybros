# Subagent Thread Control Plane Design

## Status

Approved design for the March 18, 2026 subagent control-plane refactor.

This design is intentionally destructive:

- compatibility shims are out of scope
- old subagent rows and fixtures may be discarded
- database reset is acceptable when schema or runtime truth changes

## Problem

The current subagent runtime is only half of a control plane.

Today:

- subagents are created as child `Conversation` records
- ownership and provenance live in `Conversation.metadata["subagent"]`
- `subagent_poll` and `subagent_wait` infer control truth by looking up the child conversation and synthesizing snapshots on demand
- the parent projector mostly learns subagent state from tool results rather than from a durable control-plane object
- child browsing is possible because the child is just another conversation, but authority is not explicitly modeled

That leaves five correctness gaps:

1. authority is inferred instead of owned by a first-class model
2. lifecycle and execution state are mixed together
3. owner-finalization freeze semantics are not a durable rule
4. unexpected child terminal states do not have a canonical owner-notification path
5. graph-structure invariants are too easy to regress because the parent/child join is implicit

The product semantics are now clarified:

- a subagent is a child task of an owner turn
- the child DAG may be browsed for debug and progress
- all mutation authority stays with the owner
- approvals in the child must be proxied through the owner
- when the owner turn ends, the child becomes read-only audit state
- normal completion must not silently merge the child graph into the parent graph

## Goals

- introduce a first-class subagent control-plane model
- keep the child DAG independently browsable
- make authority owner-owned and durable
- support a full parent-side control surface:
  - `subagent_spawn`
  - `subagent_run`
  - `subagent_poll`
  - `subagent_wait`
  - `subagent_send_input`
  - `subagent_resume`
  - `subagent_interrupt`
  - `subagent_approve`
  - `subagent_deny`
  - `subagent_close`
  - optional `subagent_kill`
- freeze all active child threads when the owner turn reaches a terminal state
- notify the owner when the child reaches a terminal state for any non-owner reason
- make graph join semantics explicit and testable
- move execution-context, statistics attribution, and turn projection off `Conversation.metadata["subagent"]` as runtime truth
- reserve the full subagent tool family as kernel-owned capability-snapshot routes
- require development-environment proof, not only test-suite proof

## Non-Goals

- no generalized `RuntimeThread` or `GraphSessionOwner` abstraction in this cut
- no direct mutation from the child browse page
- no child-to-parent transcript merge
- no resurrection, re-parenting, or promotion of a finished child into a normal conversation
- no attempt to model long-lived external service orchestration inside the DAG
- no change to the product decision that automation creates normal top-level conversations

## Chosen Architecture

The runtime is split into two layers:

1. `SubagentThread` is the durable control-plane object
2. child `Conversation` remains the transcript and DAG container

This keeps the runtime honest:

- the child DAG remains fully inspectable
- the control plane stops masquerading as `Conversation.metadata`
- the system can distinguish browsing from authority

The alternative of letting `Conversation` continue to carry both transcript state and control truth was rejected because it keeps lifecycle, authority, and freeze semantics distributed across metadata, tool payloads, and projector guesses.

The alternative of introducing a generalized owner abstraction was rejected for this cut because current confirmed needs only require two owner types (`Conversation` and the new subagent thread control plane), and the extra abstraction would mostly be speculative infrastructure.

## Core Model

### `SubagentThread`

Create a new `SubagentThread` Active Record model with UUIDv7 primary key. The primary key is the public `subagent_id`.

Required relationships:

- `belongs_to :owner_conversation, class_name: "Conversation"`
- `belongs_to :owner_graph, class_name: "DAG::Graph"`
- `belongs_to :owner_turn, class_name: "DAG::Turn"`
- `belongs_to :owner_node, class_name: "DAG::Node"`
- `belongs_to :child_conversation, class_name: "Conversation"`
- `belongs_to :child_graph, class_name: "DAG::Graph"`

Recommended fields:

- `status`
- `child_status`
- `depth`
- `requested_name`
- `title`
- `agent_profile`
- `context_turns`
- `diagnostic_level`
- `terminal_origin`
- `terminal_reason`
- `terminal_at`
- `freeze_reason`
- `frozen_at`
- `owner_finalized_at`
- `closed_at`
- `owner_notified_at`
- `last_snapshot` jsonb
- `final_snapshot` jsonb
- `result_summary` jsonb
- `artifacts_summary` jsonb

Optional but useful:

- `last_error_snapshot` jsonb
- `integrity_state`
- `integrity_error`

### Child `Conversation`

The child conversation remains a real `Conversation` with its own root graph and transcript APIs so the debug browse story stays simple.

However, it is no longer the source of truth for control-plane ownership.

Allowed child metadata in this cut:

- `subagent_thread_id`
- `owner_conversation_id`
- `owner_graph_id`
- `owner_turn_id`
- `owner_node_id`
- `depth`

These fields are for browse/debug discoverability only. They must not be used as the canonical control-plane join.

Any runtime path that needs subagent identity or ownership semantics must resolve through `SubagentThread` first. That includes:

- programmable execution context
- statistics attribution
- turn execution projection

## Database-Level Ownership And Anti-Orphan Invariants

The system must support database-level owner tracing for every managed child graph.

That means a child graph is not considered "tracked" merely because its conversation metadata mentions a parent. A tracked child graph must be reachable from `subagent_threads`.

Required durable ownership path:

- `subagent_threads.child_graph_id -> dag_graphs.id`
- `subagent_threads.owner_graph_id -> dag_graphs.id`
- `subagent_threads.child_conversation_id -> conversations.id`
- `subagent_threads.owner_conversation_id -> conversations.id`
- `subagent_threads.owner_turn_id -> dag_turns.id`
- `subagent_threads.owner_node_id -> dag_nodes.id`

Required database-level constraints:

- `child_conversation_id` is `NOT NULL`
- `child_graph_id` is `NOT NULL`
- `owner_conversation_id` is `NOT NULL`
- `owner_graph_id` is `NOT NULL`
- `owner_turn_id` is `NOT NULL`
- `owner_node_id` is `NOT NULL`
- `child_conversation_id` is `UNIQUE`
- `child_graph_id` is `UNIQUE`
- all owner/child references use foreign keys with restrictive delete behavior

Required application-level integrity checks:

- `child_conversation.dag_graph.id == child_graph_id`
- `owner_conversation.dag_graph.id == owner_graph_id`
- `owner_node.graph_id == owner_graph_id`
- `owner_node.turn_id == owner_turn_id`
- the child conversation remains linked to the owner conversation as its parent conversation for browse discoverability

Operational rule:

- if a child graph exists but no `SubagentThread` row points at it, it is not a valid managed subagent graph
- if a `SubagentThread` points at a missing or mismatched child graph, the thread must fail closed into `missing` or `frozen`

This gives a direct SQL ownership path. Example query shape:

```sql
select
  st.id as subagent_id,
  st.owner_conversation_id,
  st.owner_graph_id,
  st.owner_turn_id,
  st.owner_node_id
from subagent_threads st
where st.child_graph_id = $1;
```

That query must be sufficient to identify the owner of any managed child graph without reading JSON metadata.

## State Model

Control-plane state and child execution state are intentionally separate.

### `SubagentThread.status`

- `active`
- `frozen`
- `closed`
- `killed`
- `missing`

Meaning:

- `active`: owner still has authority
- `frozen`: owner turn has ended; the thread is read-only audit state
- `closed`: owner performed a graceful close
- `killed`: owner or kernel force-terminated the child
- `missing`: child conversation or graph is missing or irreparably inconsistent

### `SubagentThread.child_status`

- `pending`
- `running`
- `awaiting_approval`
- `idle`
- `failed`
- `stopped`
- `missing`

Meaning:

- `status` answers "may the owner still control this thread?"
- `child_status` answers "what is the child DAG doing right now?"

This split is a hard rule. The design intentionally forbids collapsing both dimensions into one enum.

## Runtime Surface

The kernel-owned subagent runtime surface becomes:

- `subagent_spawn`
- `subagent_run`
- `subagent_poll`
- `subagent_wait`
- `subagent_send_input`
- `subagent_resume`
- `subagent_interrupt`
- `subagent_approve`
- `subagent_deny`
- `subagent_close`
- optional `subagent_kill`

Rules:

- all mutation tools validate ownership through `SubagentThread`
- mutation tools are rejected unless `status == "active"`
- read-only tools may operate on `active`, `frozen`, `closed`, `killed`, and `missing`
- child browse pages never mutate directly
- tool alias resolution and capability snapshots must reserve the full subagent tool family as kernel-owned

## Owner Proxy Rule

Child pages are browse-only.

All mutation authority is proxied through the owner thread, even when the user is visually looking at the child conversation page.

That applies to:

- send input
- retry/resume
- interrupt
- approve
- deny
- close
- kill

The child page may display these controls in disabled form with an explicit owner link, but the request path must go through the owner-owned control plane.

## Join Semantics

There is no cross-graph merge node.

Parent and child remain separate DAGs forever.

Join semantics are parent-local:

- normal completion:
  - the parent `subagent_wait` task is the canonical join
- abnormal terminal state:
  - the kernel materializes a parent-owned `subagent_notice` or `subagent_join` task/activity

Results may influence parent output only through normal parent-side aggregation:

- parent tasks
- `after_subagent_result`
- parent assistant step
- parent `before_finalize_output`

The child may never directly inject or rewrite parent transcript content.

## Owner Notification

Unexpected terminal child states must notify the owner.

Add durable terminal attribution:

- `terminal_origin`
  - `owner_action`
  - `child_runtime`
  - `system_reconcile`
  - `integrity_guard`
- `terminal_reason`
- `owner_notified_at`

Rule:

- if `terminal_origin != "owner_action"`, the kernel must notify the owner

Notification path:

1. refresh the `SubagentThread` terminal snapshot
2. if the owner turn is still active, materialize a parent-side notice/join activity
3. if an owner wait is in progress, allow the wait path to observe the new terminal state naturally
4. record `owner_notified_at`

The child still must not write directly into the parent transcript.

## Freeze Rule

Owner finalization is authoritative.

When the owner turn reaches a terminal state:

1. find every `SubagentThread` for that owner turn with `status == "active"`
2. stop all nonterminal child DAG nodes
3. cancel nonterminal child `TurnInternalTask` rows
4. refresh `final_snapshot`
5. transition the control plane to `status = "frozen"`
6. set `frozen_at`, `owner_finalized_at`, and `freeze_reason`

After freeze:

- all mutation tools reject
- child pages are read-only
- only polling/browsing remains available

This rule intentionally forbids "owner finished but child keeps running quietly".

## Errors And Integrity

Errors are grouped into four buckets:

- authority errors
- lifecycle errors
- child runtime errors
- control-plane integrity errors

Handling rules:

- authority/lifecycle/integrity errors are tool-level validation failures
- child runtime errors are represented in `last_snapshot/final_snapshot`
- `missing` or mismatched child state is fail-closed

Integrity examples:

- `SubagentThread.child_conversation_id` points to the wrong owner
- child provenance metadata contradicts the thread row
- the child graph is missing

These become:

- `status = "missing"` or `status = "frozen"`
- no automatic reassignment
- read-only audit access only

## Recovery

This cut intentionally keeps recovery simple:

- no resurrection
- no re-parenting
- no auto-promotion to normal conversation
- no "reattach to new owner" repair flow

If data is inconsistent:

- freeze or mark missing
- capture the latest safe snapshot
- fail closed

## Testing And Acceptance

This refactor requires stronger topology verification than the existing subagent coverage.

Acceptance must include:

1. graph-structure tests
   - parent/child graphs remain separate
   - no hidden merge edges appear
   - parent-side join nodes appear in the intended cases only
   - owner-finalization freeze preserves graph invariants
2. lifecycle tests
3. authority tests
4. approval proxy tests
5. integrity tests
6. projector/read-only browse tests

Required final acceptance:

- a real development-environment run, not just test fixtures
- the implementer personally exercises subagent work in `bin/dev`
- the resulting parent and child graphs are inspected and proven correct
- the proof is written to a report under `docs/reports/`

## Migration Strategy

This is a destructive cut.

Implementation rules:

- add `subagent_threads`
- stop using `Conversation.metadata["subagent"]` as runtime truth
- rewrite subagent tools to load and mutate `SubagentThread`
- update projectors and hooks to read thread snapshots
- reset development/test databases if incompatible state blocks progress
- do not add compatibility adapters for old subagent rows

## Expected Outcome

After this refactor:

- `Conversation` remains the child transcript and DAG container
- `SubagentThread` becomes the sole authoritative control-plane object
- browsing and authority are cleanly split
- unexpected child termination is visible to the owner
- parent/child join behavior is explicit, audited, and topology-tested
