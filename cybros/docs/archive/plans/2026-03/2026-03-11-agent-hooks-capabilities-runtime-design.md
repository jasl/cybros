# Agent Hooks Capabilities Runtime Design

## Goal

Define the next-step programmable-agent runtime around:

- typed agent hooks
- agent-led capability handshake
- per-step tool-surface manifests
- unified execution context
- lane-scoped prompt working state

This design assumes the new lane-state substrate from:

- `2026-03-11-lane-state-prompt-buffer-design.md`
- `2026-03-11-context-budget-soft-limit-design.md`

This is a full runtime cutover design, not a partial experiment.
The system should migrate to this runtime model completely and remove superseded runtime logic and active documentation that would mislead future work.

What is deferred is narrower:

- proving that one specific concrete agent implementation is the right long-term strategy
- validating the quality of one concrete agent's memory / knowledge / compaction behavior in production-like scenarios

## Destructive-Cut Assumptions

- breaking changes are allowed
- no compatibility shim is required
- old `conversation.kv.*` / old prompt-working-set assumptions should not be preserved
- database reset is allowed if schema needs to move with the runtime model
- once this runtime lands, old programmable-agent runtime concepts should remain only in archived docs, not active docs

## Migration Requirement

This runtime must become the canonical programmable-agent model for active code and active docs.

That means:

- migrate `agents/default` onto this runtime model as the first bundled reference agent
- migrate bundled/default programmable-agent behavior onto this model
- migrate prompt building onto `lane.prompt_buffer`
- migrate capability routing onto snapshot + manifest semantics
- remove old runtime concepts that would cause future implementation drift

For the bundled default agent specifically:

- its current RPC and hook surfaces must be rewritten around the new runtime
- any old bundled-default interface that does not survive in the new runtime should be removed rather than preserved for compatibility
- the bundled default agent should expose the complete runtime capability expected by the new programmable-agent model, even if a future concrete agent later proves a better strategy

The only thing intentionally left unresolved is which concrete agent implementation best proves or tunes the design.

## Core Decisions

### 1. Cybros Owns Authority; The Agent Owns Strategy

Cybros remains the kernel authority for:

- DAG materialization
- tool policy / approval
- execution routing
- audit / telemetry
- hard and soft context-budget enforcement

The agent program owns:

- prompt construction
- tool-surface selection
- hook decisions
- agent-contributed tool implementations
- local memory / knowledge / MCP / skills adaptation

The LLM is only a model-facing decision surface. It does not directly own graph mutation, routing, or public-state mutation.

### 2. The Execution Abstraction Stays `tool`

Cybros should not introduce first-class execution abstractions for:

- skills
- MCP
- arbitrary agent-side procedures

Those are capability sources, not new execution primitives.

The execution abstraction inside the DAG loop remains:

- `tool`

This keeps task execution, policy, approval, telemetry, retry, and auditing uniform.

### 3. Capability Negotiation Uses Cached Snapshots

Capability negotiation happens during the Cybros <-> agent connection lifecycle.

Cybros exposes a kernel capability catalog.
The agent responds with its agent-tool catalog.
Cybros merges both into a cached `capability_registry_snapshot`.

This is not an always-live mutable registry.
It is a cached handshake result, refreshed only when:

- the kernel capability catalog changes
- the agent program changes its contributed capabilities
- an explicit manual refresh is requested

This does not remove deployment inspection / activation surfaces.

The following should remain as deployment-lifecycle methods:

- `initialize`
- `agent.describe`
- `agent.health`
- `agent.schemas.get`

The new `capabilities.handshake` / `capabilities.refresh` methods are runtime-negotiation methods layered on top of the deployment lifecycle, not replacements for deployment activation and health inspection.

### 4. Tool Selection Is Per-Step; Capability Handshake Is Not

The handshake snapshot is cached.
Prompt-time tool selection is separate.

For each step:

- the agent prompt builder selects a subset of tools from the cached snapshot
- the agent sends a thin `tool_surface_manifest`
- Cybros validates it and derives a stable `tool_surface_id`

This keeps the handshake stable while keeping prompt construction cache-friendly.

### 5. Tool Naming Uses Three Layers

Every routed tool should distinguish:

- `logical_tool_name`
- `effective_tool_id`
- `implementation_ref`

`logical_tool_name` is the stable canonical name seen by the model, policy, and reporting.
`effective_tool_id` identifies the routed implementation inside one capability snapshot.
`implementation_ref` points to the concrete kernel or agent handler.

### 6. Only `cybros_*` Is A Reserved Tool Namespace

The only reserved logical-name prefix is:

- `cybros_`

Agent programs may not register `cybros_*`.

Everything else is flexible by default.
This leaves room for agent-defined:

- `memory_*`
- `knowledge_*`
- `compact_context`
- any skill-backed or MCP-backed agent tool

Kernel-owned authority tools should migrate toward `cybros_*` naming over time.

### 7. Non-`cybros_*` Logical Tools Default To Agent Priority

For non-reserved logical names:

- if the agent contributes a tool with that logical name, the agent implementation wins
- otherwise Cybros may route to its own kernel implementation if one exists

This gives agent programs a natural override path for semantic helper tools such as `compact_context`, without introducing a separate explicit override config surface.

### 8. Every Agent-Facing Callback Receives Explicit Typed Context

All agent-facing code APIs must receive a typed context object rather than relying on ambient globals.

At minimum:

- `account_id`
- `user_id`
- `conversation_id`
- `graph_id`
- `lane_id`
- `turn_id`

This is required for:

- tenant isolation
- branch-local memory / knowledge behavior
- auditable tool execution
- replay-safe hook and tool behavior

Handshake-time APIs may use a lighter `session_context`, but they should still include:

- `account_id`
- `user_id`
- `conversation_id`

### 9. Hooks Are Typed Code Callbacks Returning Typed Actions

Hooks are not middleware and not raw DAG mutation APIs.

They are agent program callbacks:

- invoked by Cybros
- given typed input
- returning typed action envelopes

V1 hook entrypoints:

- `on_conversation_created`
- `before_agent_step`
- `on_context_pressure`
- `on_hardcap_reached`
- `before_subagent_spawn`
- `after_subagent_result`
- `before_finalize_output`
- `on_tool_error`
- `on_subagent_error`
- `on_context_recovery_error`
- `on_runtime_error`

V1 action kinds:

- `noop`
- `emit_message`
- `create_task`
- `halt`
- `deny`

Hooks should return an ordered `actions[]` list, not a single scalar intent.
This is required so one hook invocation can:

- prepend one `compact_context` task
- append multiple `subagent` tasks
- emit a message and then append follow-up work

V1 sequencing rules:

- actions are materialized in declaration order
- `prepend` still means `defer + run + resume`
- `append` means serialized follow-up work after the current action
- `parallel` is intentionally out of scope
- terminal actions such as `halt` or `deny` should appear at most once and only at the tail of the action list

`create_task` uses:

- `logical_tool_name`
- `input`
- `placement: prepend | append`

`prepend` means:

- defer current action
- run the prepended task
- resume the deferred continuation

This is required for `compact_context`, hard-cap recovery, and multi-subagent fanout flows.

Error hooks are intentionally scoped to the agent loop / conversation runtime.

They should be used for failures where the agent may still:

- choose a recovery strategy
- emit user-visible feedback
- change follow-up work inside the conversation DAG

They should not be used for deployment / startup / contract failures such as:

- `initialize`
- `agent.describe`
- `agent.health`
- `agent.schemas.get`
- capability-handshake or refresh contract violations
- invalid hook action envelopes
- reserved-name / contract-invariant failures

Those failures should remain fail-fast kernel errors rather than recursively invoking runtime hooks.

Within the agent loop, error handling should prefer specific hooks first:

- `on_tool_error`
- `on_subagent_error`
- `on_context_recovery_error`

`on_runtime_error` is the final fallback for loop/conversation failures that are not covered by a more specific runtime hook.

For `agents/default`, this means the old `turn.prepare` / `turn.compose` / `turn.handle_error` contract is not the long-term canonical interface.
The bundled default agent must be remapped onto the new hook set.
Any legacy RPC method still present after the cut must be justified as part of the new model; otherwise it should be removed.

### 9.1 `RunDraft` Planning And Staged Mutation Semantics Survive The Hook Cutover

The runtime must not lose the current product semantics around:

- durable `RunDraft`
- staged settings/config/lane-state mutation
- execution-target proposal during planning
- approval park / resume without replaying planning

Those semantics should be remapped onto the new hook-driven runtime rather than deleted.

In practice:

- the pre-execution planning phase currently modeled as `turn.prepare` must be re-expressed through typed hook entrypoints and typed kernel surfaces
- staged mutation and approval semantics still terminate at `RunDraft`
- approval resume must still continue from persisted prepared state instead of replaying the same planning work

This is a runtime-shape migration, not permission to drop draft semantics.

### 9.2 Subagents Are Background Agent Threads, Not Child Conversations

For programmable-agent runtime semantics, `subagent` should not default to “human-facing child conversation”.

The intended model is:

- a background agent thread
- agent-owned delegated work
- no assumption of direct human interaction

This means subagent fanout / fan-in should not be modeled as lane merge and should not depend on conversation merge semantics.

### 9.3 `merge_lane_state` And Subagent Aggregation Stay Separate

`merge_lane_state` is for:

- same-graph lane merges
- branch-local state merge
- `lane.kv` / `lane.prompt_buffer` reconciliation

It is not the default fan-in primitive for subagent work.

Subagent aggregation should instead use parent-side explicit tasks, for example:

- `subagent_run`
- `subagent_wait`
- `collect_subagent_results`
- `synthesize_subagent_results`

This keeps:

- lane merge semantics focused on graph-internal branches
- subagent semantics focused on delegated background work
- DAG auditing explicit at each step

Current kernel-owned subagent APIs that assume child-conversation semantics must be migrated or removed as part of this cut.
The runtime must not keep one subagent model in active programmable-agent docs and another in active `subagent_*` tool docs.

### 10. Prompt Working State Belongs To `lane.prompt_buffer`

Prompt-side working material is not DAG history.

The prompt builder should organize sections from:

- DAG history window
- `lane.prompt_buffer`
- `lane.kv`
- memory / knowledge providers
- tool surface
- budget facts

The section model should at least cover:

- `system`
- `developer`
- `history`
- `summaries`
- `working_notes`
- `handoff`
- `memory`
- `tools`
- `budget_guidance`

`summaries`, `working_notes`, and `handoff` should come from `lane.prompt_buffer`, not from legacy conversation-scoped working memory.

### 11. Prompt Shrink Should Prefer Buffer-Layer Material Before History

Budget pressure should shrink prompt-side working state before durable history:

1. `working_notes`
2. `summaries`
3. `handoff`
4. `memory`
5. `tools`
6. `history` last

This keeps the new lane-state model meaningful and prevents the system from treating DAG history as prompt working memory again.

### 12. `compact_context` Is A Tool Contract, Not A Hidden Side Channel

`compact_context` remains a tool-shaped operation.

Its default implementation should:

- rewrite `lane.prompt_buffer`
- summarize or compact prompt-side sections
- avoid mutating durable history by default

Only when durable graph compaction is explicitly needed should the system move on to DAG `summary` node behavior.

The logical tool name can stay `compact_context`.
Whether the routed implementation is kernel-managed or agent-managed is recorded in execution metadata.

### 13. Tool Surface And Routing Need Stable Audit Identifiers

Each step should record:

- `capability_registry_snapshot_id`
- `kernel_capability_registry_version`
- `tool_surface_id`
- `tool_surface_label`
- `logical_tool_name`
- `implementation_source`
- `implementation_ref`
- `agent_program_id`
- `agent_program_version`

This is required for:

- replay
- audit
- prompt-cache analysis
- per-agent tool success-rate reporting

### 14. Telemetry Must Compare Logical Tool Success Across Implementations

The runtime should be able to answer:

- how often this agent calls tools successfully
- whether `compact_context` is more successful as an agent implementation or a kernel implementation
- which `tool_surface_id` clusters are unstable

At minimum, tool-task telemetry should capture:

- `result_status`
- `latency_ms`
- `error_code` when applicable
- `logical_tool_name`
- `implementation_source`
- `tool_surface_id`

## Public API Sketch

### Capability Handshake

`capabilities.handshake`

Cybros -> agent:

- `session_context`
- `kernel_capability_registry_version`
- kernel capability catalog

agent -> Cybros:

- `agent_program_id`
- `agent_program_version`
- agent tool catalog

Result:

- `capability_registry_snapshot_id`
- merged effective tool routes

For the bundled default agent, this handshake should become the primary runtime discovery path instead of the old narrow manifest-only RPC contract.

### Capability Refresh

`capabilities.refresh`

Input:

- `last_snapshot_id`
- `last_kernel_registry_version`
- `reason`

Output:

- `unchanged`, or
- a refreshed snapshot after re-running handshake

### Tool Surface Manifest

`tool_surface.manifest`

Input:

- `execution_context`
- `capability_registry_snapshot_id`
- `selected_tool_ids`
- optional `tool_surface_label`

Result:

- validated manifest
- stable `tool_surface_id`

### Agent Tool Execution Callback

When a routed tool resolves to an agent implementation, Cybros calls the agent with:

- `execution_context`
- `capability_registry_snapshot_id`
- `tool_surface_id`
- `logical_tool_name`
- `effective_tool_id`
- `implementation_ref`
- typed `input`

The result flows back through the same task / projection / telemetry path as any other tool call.

### Hook Action Envelope

Hook results should use an action envelope of the form:

```json
{
  "actions": [
    {
      "kind": "create_task",
      "task": {
        "logical_tool_name": "compact_context",
        "input": {},
        "placement": "prepend"
      }
    }
  ]
}
```

Multiple `create_task` actions in one envelope are valid and are the expected way to express multi-subagent fanout from hooks.

## Non-Goals For This Round

- choosing the final production-grade agent strategy
- proving one concrete production-grade agent is already optimal
- introducing a second execution abstraction beside `tool`
- preserving `conversation.kv.*`
- keeping old prompt-working-set semantics alive for compatibility
- making `skills` a first-class Cybros execution primitive
- building a generalized live capability-registry control plane
- preserving bundled-default legacy RPC hooks that are not part of the new runtime contract

## Validation Posture

This design should be validated in two stages:

1. full runtime cutover validation
   - hook payloads
   - capability snapshots
   - manifest validation
   - tool routing
   - telemetry shape
   - prompt-builder boundaries
   - removal of superseded active-path runtime logic
   - removal of superseded active docs

2. concrete-agent validation
   - one or more real agent programs
   - real memory / knowledge behavior
   - real compaction behavior
   - real prompt-cache and success-rate observations

Stage 2 is intentionally deferred.
