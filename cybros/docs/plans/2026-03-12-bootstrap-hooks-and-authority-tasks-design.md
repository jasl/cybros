# Bootstrap Hooks And Authority Tasks Design

## Status

Approved design notes for extending the programmable-agent runtime with bootstrap-family hooks without introducing a new DAG primitive.

This design follows the current runtime direction:

- `task` remains the execution abstraction
- `cybros_*` remains the reserved kernel namespace
- any product-state mutation must stay Cybros-owned and auditable through DAG execution

## Problem

The current programmable-agent runtime has no clean lifecycle surface for three important moments:

- conversation creation before any user input
- lane creation when a new lane or branch becomes available
- the first real user message, which often needs conversation-level follow-up such as title generation

Today those needs have no explicit programmable contract.

That creates two failure modes:

- pressure to perform direct state mutation outside the DAG
- pressure to overload existing runtime hooks that were designed for planning or live-step execution

Both outcomes would weaken the runtime boundary.

## Goals

- add explicit lifecycle hooks for bootstrap moments that matter semantically
- keep all agent-driven state change visible in the DAG
- avoid introducing a new persisted DAG entity such as `delegate_task` or `change_request`
- preserve Cybros authority over product state mutation, execution policy, and audit
- support welcome/self-introduction messages, bootstrap state initialization, lane-local summary bootstrap, and first-message title generation

## Non-Goals

- no direct conversation or lane mutation from hook callbacks
- no new generic DAG node type
- no requirement that every bootstrap action involve an LLM
- no expansion of V1 bootstrap hooks into arbitrary agent-owned delegate work

## Core Decision

Do not add a new DAG primitive.

Instead:

- add two new programmable lifecycle hooks:
  - `on_conversation_created`
  - `on_lane_first_user_message`
- keep V1 bootstrap hooks append-only and authority-only
- express all bootstrap side effects as `create_task(append)` actions targeting reserved `cybros_*` logical tools

This preserves a single execution abstraction:

- the hook decides **what follow-up work should happen**
- Cybros materializes that work as DAG tasks
- Cybros-owned authority tools apply any product-state changes

## Why Authority Tasks Instead Of Direct Mutation

Current mutation callbacks such as:

- `conversation.settings.update`
- `conversation.config.update`
- `lane.kv.set`

are implemented on `run_draft` scope and stage changes on the draft before finalization.

That shape is correct for planning, but it is the wrong shape for bootstrap hooks that fire:

- before a draft exists
- outside a live assistant-step placeholder
- sometimes before any `ConversationRun` exists

Bootstrap hooks therefore must not mutate state through callback RPCs.

Instead they should enqueue explicit Cybros-owned authority tasks whose execution:

- is visible in the DAG
- is replay-safe
- is policy-gated
- leaves a normal task/audit trail

## New Hook Family

### 1. `on_conversation_created`

Purpose:

- conversation-level bootstrap for a newly created `Conversation`
- welcome/self-introduction message on the main lane
- initial conversation/lane state bootstrap

Timing:

- fire after the `Conversation` is persisted
- fire only after `graph.main_lane` exists and is attached to that conversation
- fire before any user-authored message exists on the conversation lane
- fire once per `Conversation`

V1 allowed intent:

- `noop`
- `create_task(append)` only

V1 expected authority tasks:

- `cybros_seed_message`
- `cybros_bootstrap_state`

### 2. `on_lane_first_user_message`

Purpose:

- react to the first real user-authored message on an individual lane
- title generation and other lane-first-message semantic follow-up
- defer branch-lane summary work until the lane has real user-authored content

Timing:

- fire only when the first persisted `Messages::UserMessage` is created for a given lane
- seeded system/developer/assistant/product messages do not count
- fire once per lane
- fire after the first turn graph is materialized so the hook can anchor follow-up work to the real turn

V1 allowed intent:

- `noop`
- `create_task(append)` only

V1 expected authority tasks:

- `cybros_generate_title`
- `cybros_enqueue_lane_summary` for branch lanes only

## Trigger Ordering

The ordering rule should be explicit:

1. `Conversation` persists
2. `graph.main_lane` is ensured and attached
3. `on_conversation_created` fires
4. later, the first persisted user-authored message on that lane causes `on_lane_first_user_message`

For branch creation:

1. branch `Conversation` persists
2. branch lane/root node is created and attached
3. `on_conversation_created` fires for the branch conversation
4. later, the first user-authored message on that branch lane may fire `on_lane_first_user_message`

These hooks are intentionally distinct:

- conversation bootstrap should own welcome/bootstrap semantics
- first-user-message should own semantic follow-up derived from actual user intent
- branch-lane summary should wait until lane-first user intent actually exists

## Authority Task Catalog

### `cybros_seed_message`

Purpose:

- write a visible assistant-style bootstrap message to a lane

Expected payload:

- `lane_id`
- `message`
- optional `message_role`
- optional `exclude_from_context`
- optional `metadata`

V1 behavior:

- materialize a terminal visible message node on the target lane
- allow immediate `exclude_from_context` when requested so welcome/bootstrap text does not pollute later prompt context

### `cybros_bootstrap_state`

Purpose:

- initialize conversation/lane state without bypassing the DAG

Expected payload:

- optional `public_settings_patch`
- optional `agent_config_patch`
- optional `kv_ops`
- optional `prompt_buffer_ops`

V1 behavior:

- apply Cybros-owned mutations directly during task execution
- write audit-visible task metadata
- fail atomically if the payload is invalid

### `cybros_generate_title`

Purpose:

- derive and apply a conversation title after the first user message

Expected payload:

- `conversation_id`
- `lane_id`
- `user_node_id`
- optional generation strategy metadata

V1 behavior:

- generate a candidate title through a Cybros-owned strategy
- apply the final `conversation.title` update inside Cybros
- never expose raw title mutation as an agent-owned callback

The strategy implementation may evolve later.
The authority boundary does not.

### `cybros_enqueue_lane_summary`

Purpose:

- mark or enqueue lane-local summary/bootstrap follow-up after the first user-authored message on a branch lane

V1 behavior:

- stay kernel-owned
- may be a lightweight bootstrap marker at first rather than a full summarization engine

## Routing Rule For Bootstrap Hooks

Bootstrap hooks do not require a validated per-step tool surface in the same way as normal assistant-step execution.

The routing rule for V1 bootstrap hooks should be:

- only reserved `cybros_*` logical tools are legal
- those tools route directly through the kernel tools registry
- bootstrap hooks may not target agent-program tools

This avoids the current `conversation_run` / validated tool-surface dependency that ordinary hook-created runtime tasks rely on.

## DAG And Anchoring Rules

### Empty main lane bootstrap

`on_conversation_created` must support appending the first executable or visible work item even when no assistant-step placeholder exists yet.

V1 rule:

- bootstrap append on an empty lane may create the first node directly on that lane
- continuation-splicing logic that assumes an existing placeholder is not used for this hook family

### Branch lane bootstrap

When a branch lane already has a root node, append relative to that lane head.

### First-message follow-up

`on_lane_first_user_message` should anchor follow-up after the newly created first turn, not before it, so title generation or similar work does not delay the first assistant reply unnecessarily.

If a pending agent placeholder exists for that first turn:

- append after that turn’s live assistant node

If the turn ends in a terminal non-agent product path:

- append after the current terminal lane head

## Data Flow Rule

The user requirement here is strict:

- all agent-caused conversation state change must be reflected in the DAG

The resulting flow is:

- hook returns authority-task intent
- Cybros materializes a task node
- the authority task executes
- the task mutates conversation/lane state
- transcript/audit/observability can trace both the request and the result

No hidden callback mutation path is used for this hook family.

## Validation And Policy

Bootstrap-family hooks should get their own policy matrix in `HookEnvelope`:

- `on_conversation_created`: `noop`, `create_task(append)` only
- `on_lane_first_user_message`: `noop`, `create_task(append)` only

Additional V1 validation:

- bootstrap hooks may not return `planning`
- bootstrap hooks may not emit `set_step_status`, `emit_message`, `halt`, or `deny`
- bootstrap hooks may only create tasks with reserved `cybros_*` logical names
- bootstrap authority-task payloads must be validated by kernel-owned tool schemas

## Default Agent Contract

The bundled default agent should expose these new methods in V1, even if its first implementation is conservative:

- `on_conversation_created`
- `on_lane_first_user_message`

The bundled implementation may initially:

- seed a short welcome message
- initialize minimal state
- request title generation after first user message
- request branch-lane summary only after the first branch-lane user message

That keeps the bundled agent aligned with the public runtime contract.

## Documentation Consequences

Active public docs must be updated together with the code.

At minimum:

- add the new hook family to `docs/product/agent_rpc.md`
- document `tool.execute` and `tool_surface.manifest` in active public API docs
- remove or correct the current claim that raw JSON Schema artifacts stored in the repo are already the canonical shipped source of truth
- document the authority-task boundary in `docs/product/kernel_service_surface.md` and `docs/product/programmable_agents.md`

## Non-Goals For This Cut

- no arbitrary agent-program delegate tasks from bootstrap hooks
- no generic `delegate_task` DAG primitive
- no direct hook-time mutation callbacks outside DAG execution
- no title-generation product polish beyond a correct authority-owned path

## Follow-On Option

If bootstrap quality later proves too constrained, the next expansion path is:

- keep bootstrap hooks as DAG-visible task producers
- allow a narrower class of delegated follow-up tasks after the authority boundary is proven stable

That follow-on should extend the task-routing contract.
It should not replace the authority-task rule for Cybros-owned product mutation.
