# Agent Hooks Capabilities Runtime Design

## Goal

Define the next-step programmable-agent runtime around:

- typed agent hooks
- agent-led capability handshake
- per-step tool-surface manifests
- unified execution context
- lane-scoped prompt working state

This design assumes the landed lane-state substrate from:

- `docs/archive/plans/2026-03/2026-03-11-lane-state-prompt-buffer-design.md`
- `docs/archive/plans/2026-03/2026-03-11-context-budget-soft-limit-design.md`

This is a full runtime cutover design, not a partial experiment.
The system should migrate to this runtime model completely and remove superseded runtime logic and active documentation that would mislead future work.

## Current Baseline

This design does **not** start from the old conversation-global programmable-agent substrate.

The current shipped baseline already includes:

- `lane.kv`
- `lane.prompt_buffer`
- `tokens.*`
- `merge_lane_state`
- prompt assembly reading `lane.prompt_buffer`
- context-budget logic built on that substrate

What remains legacy today is the programmable-agent runtime shape around that substrate:

- bundled default agent still exposes `turn.prepare` / `turn.compose` / `turn.handle_error`
- planning still enters through `turn.prepare`
- active programmable-agent protocol docs still describe that wire shape as canonical

This design is therefore a runtime cutover on top of an already-landed lane-state/context-budget base, not a greenfield redesign of those lower layers.

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
- `execution_scope`

`execution_scope` should be explicit rather than inferred from legacy metadata.
V1 values should be:

- `primary`
- `subagent`

When `execution_scope = "subagent"`, `execution_context` should also carry a typed `subagent` object.
At minimum:

- `subagent_id`
- optional `parent_turn_id`
- optional `parent_dag_node_id`
- optional `depth`

This is required for:

- tenant isolation
- branch-local memory / knowledge behavior
- auditable tool execution
- replay-safe hook and tool behavior
- letting agent code distinguish the primary turn executor from a delegated subagent worker

Handshake-time APIs may use a lighter `session_context`, but they should still include:

- `account_id`
- `user_id`
- `conversation_id`

For lifecycle hooks that do not yet have a current running step, the runtime may still supply an `execution_context`, but step-scoped fields such as:

- `turn_id`
- `dag_node_id`

may be `nil`.

This is especially relevant for `on_conversation_created`: it is allowed to schedule follow-up work, but it is not allowed to pretend a current assistant step already exists.

The same rule applies to subagent metadata:

- `execution_scope` may still be meaningful even when no current step exists
- `subagent.subagent_id` should remain stable for the delegated worker
- step-scoped parent linkage such as `parent_turn_id` may be `nil` until the runtime can anchor it safely

### 9. Hooks Are Typed Code Callbacks Returning Typed Actions

Hooks are not middleware and not raw DAG mutation APIs.

They are agent program callbacks:

- invoked by Cybros
- given typed input
- returning typed action envelopes

V1 hook entrypoints:

- control hooks:
  - `on_conversation_created`
  - `before_agent_step`
  - `on_context_pressure`
  - `before_subagent_spawn`
  - `before_finalize_output`
- terminal notice hooks:
  - `after_task_notice`
  - `after_subagent_result`

The split is intentional and should stay orthogonal:

- control hooks run while the current conversation step is still live and may continue
- terminal notice hooks run after a materialized task has already reached a terminal result
- only control hooks may use `prepend = defer + run + resume`
- terminal notice hooks may only schedule explicit follow-up work after the failed/completed task
- startup, deployment, transport, and hook-contract failures remain kernel fail-fast paths and do not dispatch notice hooks

`after_task_notice` is the canonical terminal notice for kernel/provider-managed task outcomes that are relevant to the agent loop.
Typical `notice.kind` values include:

- `provider_error`
- `hardcap_reached`
- `permission_denied`
- `remote_tool_failed`
- `remote_tool_timed_out`
- `remote_tool_denied`

`after_task_notice` is not a general fallback for every kernel failure.
It is only valid when:

- a concrete DAG task already exists
- that task has already terminated
- Cybros still has a healthy enough agent callback channel to notify the agent program

This intentionally excludes:

- `initialize`
- `agent.describe`
- `agent.health`
- `agent.schemas.get`
- capability-handshake / refresh failures
- invalid hook envelopes
- reserved-name / invariant violations
- deployment / transport failures where the agent cannot be called safely

Those failures remain fail-fast kernel errors rather than recursively invoking runtime hooks.

The hook families should also remain orthogonal by execution phase:

- planning control:
  - `before_agent_step` while `step.phase = planning`
- live-step control:
  - `on_conversation_created`
  - `on_context_pressure`
  - `before_subagent_spawn`
  - `before_finalize_output`
- terminal notices:
  - `after_task_notice`
  - `after_subagent_result`
- fail-fast kernel paths with no hook:
  - startup / deployment / transport / schema / invariant failures

V1 action kinds:

- `noop`
- `emit_message`
- `set_step_status`
- `create_task`
- `halt`
- `deny`

Hooks should return an ordered `actions[]` list, not a single scalar intent.
This is required so one hook invocation can:

- set a placeholder status such as "processing"
- prepend one `compact_context` task
- append multiple `subagent` tasks
- emit a message and then append follow-up work

The runtime also needs one durable planning contract for the planning phase.

`before_subagent_spawn` should be interpreted as a spawn-family hook rather than a single raw tool-name hook.
In V1 it must dispatch before any task that would start a delegated background worker, including:

- `subagent_spawn`
- `subagent_run`

This keeps:

- one policy surface for delegated-worker admission control
- one place to prepend recovery work before a delegated worker is launched
- `subagent_run = spawn + kick + initial snapshot` aligned with the same parent-side spawn authority as `subagent_spawn`
That contract is separate from `actions[]`:

- `planning` carries step intent that must survive approval park / resume
- `actions[]` carries immediate step-local effects for the currently running step
- kernel-owned runtime state remains authoritative for persistence, routing, and transcript mutation

In practice this means:

- `before_agent_step` during planning may return both `planning` and `actions[]`
- all other runtime hooks return `actions[]` only
- anything that must survive resume belongs in `planning`, not in `actions[]`
- anything that only affects the current running step belongs in `actions[]`

The durable planning shape should be:

- `step_plan`
- `staged_mutations`
- `execution_target_proposal`
- `approval_request`
- `tool_surface`
- `planned_tasks`

`staged_mutations` should contain:

- `public_settings_patch`
- `agent_config_patch`
- `kv_ops`
- `prompt_buffer_ops`

The authority split is intentional:

- the agent may request approval through `planning.approval_request`
- Cybros remains authoritative for persisted `approval_state`
- the agent may propose execution-target changes through `planning.execution_target_proposal`
- Cybros remains authoritative for the actual selected execution target
- the agent may select the step tool surface through `planning.tool_surface`
- Cybros remains authoritative for manifest validation and effective tool routing

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

`create_task` is intentionally narrower than planning-time task selection:

- it may add neighboring work for the currently active execution flow
- it may not rewrite the current task's core identity after materialization
- it may not specify `effective_tool_id` or `implementation_ref`
- route selection still happens in Cybros through the capability snapshot and validated tool surface

`create_task` also has hook-family-specific limits:

- control hooks may use `prepend` or `append` when their policy allows it
- terminal notice hooks may use `append` only
- terminal notice hooks may not attempt to re-open or rewrite the already-terminal task they were notified about
- runtime execution should distinguish the visible placeholder target from the sequencing anchor:
  - `set_step_status` always targets the current parent assistant placeholder
  - `create_task` sequences relative to the current execution anchor, which may be the same agent step or a downstream task such as `subagent_wait`

`set_step_status` uses:

- `text`
- optional `state`

`set_step_status` is intentionally narrow:

- it does **not** expose arbitrary message editing
- it only targets the current running agent step's placeholder / pending assistant bubble
- it exists so hooks can surface concise progress such as "processing", "compacting context", or "waiting for subagent"
- it should project into the same visible assistant bubble that already exists for pending/running agent nodes
- each new `set_step_status` replaces the previously displayed placeholder status for that step
- final output replaces that placeholder content rather than creating a second transcript message

This keeps the runtime aligned with the shipped placeholder-bubble / streaming model while avoiding a general-purpose node-edit API.

`emit_message` is likewise narrow:

- it finalizes the current running step's placeholder / pending assistant bubble
- it does not append a second transcript assistant message for that same step
- if the runtime needs another assistant-visible message, it must create a later step rather than editing transcript history in place

`prepend` means:

- defer current action
- run the prepended task
- resume the deferred continuation

This is required for `compact_context`, context-pressure recovery, and multi-subagent fanout flows.

For example:

- `before_agent_step` may set `"processing"`
- a later hook may update it to `"compacting context"`
- `before_subagent_spawn` or `after_subagent_result` may update it to `"waiting for subagent"` or `"summarizing results"`
- terminal notice hooks may replace it with a concise failure status before a final follow-up message is emitted

The planning/runtime split should stay explicit in validation:

- only `before_agent_step` in planning phase may return `planning`
- `on_conversation_created` may not use `set_step_status` because no current assistant-step placeholder exists yet
- `before_agent_step` in planning phase should not directly `create_task` or `emit_message`; those durable intentions belong in `planning`
- `before_agent_step` in planning phase may `halt` the pending step, but it may not `deny`; pending agent placeholders have a clean stop transition but not a generic reject transition
- `before_finalize_output` is the main hook that may turn the placeholder into final output through `emit_message`
- terminal notice hooks may not return `planning`, `deny`, `halt`, or `create_task(prepend)`

The runtime should also keep a hook-policy matrix so the contract is auditable rather than inferred from scattered examples.
The intended V1 policy is:

- `on_conversation_created`: `noop`, `create_task(append)` only
- `before_agent_step` during planning: `planning`, `noop`, `set_step_status`, `halt`
- `on_context_pressure`: `noop`, `set_step_status`, `create_task(prepend|append)`, `halt`
- `before_subagent_spawn`: `noop`, `set_step_status`, `create_task(prepend)`, `deny`, `halt`
- `after_task_notice`: `noop`, `set_step_status`, `create_task(append)`, `emit_message`
- `after_subagent_result`: `noop`, `set_step_status`, `create_task(append)`, `emit_message`
- `before_finalize_output`: `noop`, `set_step_status`, `emit_message`, `create_task(append)`, `halt`

This keeps:

- planning-time durable intent inside `planning`
- placeholder/status mutation inside `actions[]`
- terminal notifications narrowly focused on follow-up work after already-terminal task outcomes
- fail-fast kernel errors out of the agent hook surface entirely

`emit_message` sequencing should also be explicit:

- `emit_message` finalizes the current placeholder content
- no later action in the same envelope may call `set_step_status` or a second `emit_message`
- later `create_task(append)` actions are still allowed so the runtime can emit final output and schedule explicit follow-up work in later steps

The validator layers should map directly to this contract:

- `EnvelopeValidator` for top-level shape and unknown keys
- `PlanningValidator` for durable planning fields and authority boundaries
- `ActionListValidator` for sequencing, tail-only terminal actions, and per-action field validation
- `HookPolicyValidator` for hook-specific allowed actions and planning eligibility

The implementation should also use explicit contract objects so runtime code is not passing around ad-hoc hashes forever.
At minimum the runtime should converge on typed objects equivalent to:

- `HookEnvelope`
- `PlanningEnvelope`
- `StagedMutations`
- `ExecutionTargetProposal`
- `ApprovalRequest`
- `ToolSurfaceSelection`
- `PlannedTask`
- `HookAction::Noop`
- `HookAction::SetStepStatus`
- `HookAction::CreateTask`
- `HookAction::EmitMessage`
- `HookAction::Halt`
- `HookAction::Deny`

Validation failures should also have a clean error taxonomy rather than one-off strings.
At minimum the runtime should group them under:

- `cybros.programmable_agent.hook_contract.*`
- `cybros.programmable_agent.hook_policy.*`
- `cybros.programmable_agent.hook_action.*`
- `cybros.programmable_agent.runtime.*`

Examples include:

- invalid top-level envelope shape
- `planning` returned from a non-planning hook
- direct agent mutation of `approval_state`
- invalid task placement
- `emit_message` followed by another output/status mutation
- placeholder updates when no current placeholder exists
- attempts to rewrite a materialized task or force a routed implementation id

The notification boundary is intentionally narrow:

- control hooks are where the agent decides how to steer an in-flight conversation step
- terminal notice hooks are where the agent may inspect a completed failure/result fact and schedule explicit follow-up work
- kernel/provider failures are not magically “handled” by the agent; they remain failed facts in Cybros-owned execution state
- the agent may react to those facts by appending new tasks or emitting user-visible follow-up output, but it may not rewrite the original failed task into success

Agent-implemented tool failures do not need a second hook family.
They are ordinary agent callback results and should flow through the normal task/result path rather than recursively dispatching another agent error hook.

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
- the current `prepared_plan` concept should be replaced with a typed `planning` envelope persisted into `RunDraft`
- current planning-time prompt fragments should be replaced by typed `staged_mutations.prompt_buffer_ops`
- any work that must survive approval park / resume should be stored in `planning.planned_tasks`, not in transient runtime actions

This is a runtime-shape migration, not permission to drop draft semantics.

### 9.1.1 Durable Planning And Runtime Actions Must Stay Orthogonal

The runtime should draw a hard line between three kinds of state:

- `planning`
- `actions[]`
- kernel-owned runtime state

`planning` is for:

- durable step intent
- staged mutation
- approval requests
- execution-target proposals
- step-scoped tool-surface selection
- planned follow-up work that must survive resume

`actions[]` is for:

- placeholder status updates
- immediate prepend / append work in the active execution flow
- finalizing the current placeholder with output
- halting the current hook-driven continuation, or denying a later running-stage control action whose subject already has reject semantics

Kernel-owned runtime state is for:

- persisted `approval_state`
- capability snapshots
- effective tool routes
- current placeholder identity
- transcript mutation
- final conversation-run snapshots

This avoids conflating:

- durable draft planning with ephemeral runtime side effects
- approval requests with authoritative approval state
- task planning with task rewriting after materialization

The bundled/default agent should move from:

- `prepared_plan`
- `prompt_fragments`
- planning-time callback mutation as the primary contract

to:

- typed `planning`
- typed `staged_mutations`
- narrow `actions[]`

Planning-time callbacks may still exist for kernel-owned read APIs and proposal surfaces, but staged mutation should be represented through the typed planning contract rather than by side-effect-first callback behavior.

### 9.2 Subagents Are Background Agent Threads, Not Child Conversations

For programmable-agent runtime semantics, `subagent` should not default to “human-facing child conversation”.

The intended model is:

- a background agent thread
- agent-owned delegated work
- no assumption of direct human interaction

The boundary should be explicit:

- `conversation` is the human-agent transcript / turn boundary
- `child conversation` may still exist elsewhere in the product for explicit human-visible follow-up flows, but it is not the programmable-agent runtime substrate
- `subagent` is an execution-scoped delegated worker owned by the parent turn

This means programmable-agent subagents are not modeled as:

- a second human-visible transcript stream
- a new assistant conversation authority
- a direct writer of parent placeholder or transcript state

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

### 9.4 Subagent Results Join Through Parent-Owned Contracts

Subagent completion should produce a parent-consumable result payload rather than directly mutating transcript state.

The result contract should support:

- structured machine-readable result data
- artifacts / references produced by the delegated run
- bounded status / error metadata
- optional user-facing draft text as `assistant_output_candidate`

`assistant_output_candidate` means:

- text or structured rich-content draft that could be shown to the user
- a candidate for the parent turn's final answer, not a committed transcript message
- parent-owned material that may be accepted, rewritten, truncated, combined with siblings, or ignored

It must **not** mean:

- a second assistant transcript message
- direct placeholder replacement by the subagent
- transcript authority outside the parent step's `emit_message`

The parent-side aggregation flow should be:

1. `subagent_run` starts a delegated background agent thread / task.
2. `subagent_wait` observes lifecycle completion without creating a child-conversation semantic dependency.
3. `collect_subagent_results` normalizes structured outputs, artifacts, and optional `assistant_output_candidate` payloads.
4. `synthesize_subagent_results` decides what becomes final parent-turn output candidate material.
5. `before_finalize_output` / `emit_message` is still the only path that may replace the current parent placeholder and write final transcript output.

This keeps final answer authority in one place while still allowing delegated workers to contribute user-facing draft content.

### 9.5 Parent Turn Owns Visibility, Audit, And Transcript Mutation

For subagent flows, the parent turn remains authoritative for:

- placeholder lifecycle
- user-visible status
- final transcript mutation
- approval / denial state
- routing and telemetry attribution

Subagents may have their own internal execution logs and status transitions, but those are runtime/debug artifacts, not a substitute for parent-turn output semantics.

If the UI needs to expose subagent progress, it should do so as:

- parent-owned status projection
- explicit task/debug views
- bounded result previews

not as a second human-interactive transcript that competes with the parent turn.

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

The runtime cutover is not complete unless the agent-facing public API and the exchanged payload schemas are documented as active reference material.
That documentation should be treated as part of the shipped contract, not as optional implementation notes.

At minimum the active docs should cover:

- the agent public API surface and method list
- which methods are deployment-lifecycle methods versus runtime methods
- the typed shape of `session_context` and `execution_context`, including `execution_scope` and `execution_context.subagent`
- the typed request/response schemas for:
  - `initialize`
  - `agent.describe`
  - `agent.health`
  - `agent.schemas.get`
  - `capabilities.handshake`
  - `capabilities.refresh`
  - hook invocations
  - agent-tool execution callbacks
  - tool-surface manifest submission
- which fields are agent-authored, which are kernel-authored, and which are derived/validated
- which fields are durable across park / resume versus step-local runtime fields
- validation and error semantics for malformed envelopes / schemas

Those schemas should be documented in a way that is easy to audit and keep in sync with implementation.
Ad-hoc prose examples alone are not sufficient; active docs should include stable field-level schemas or schema-equivalent contract tables for the runtime payloads.

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

The validated tool surface is the step allowlist for execution, not merely a rendering hint for model-visible tools.
That means:

- model-issued tool calls must resolve inside the validated tool surface
- hook-issued `create_task` actions must also resolve inside the validated tool surface unless the kernel explicitly injects a reserved authority task
- runtime routing still records `logical_tool_name`, `effective_tool_id`, and `implementation_ref` after validation

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

### Task Notice Exchange

Kernel/provider-managed terminal task outcomes that are not themselves agent-authored should be delivered through a typed terminal-notice callback rather than a generic runtime-error hook.

At minimum the exchanged task-notice schema should distinguish:

- `task_id`
- `status`
- `notice.kind`
- optional `logical_tool_name`
- optional `error`
- optional `artifacts`
- optional `retryable`
- optional `user_decision_required`

Typical `notice.kind` values should include:

- `provider_error`
- `hardcap_reached`
- `permission_denied`
- `remote_tool_failed`
- `remote_tool_timed_out`
- `remote_tool_denied`

The schema contract should make these boundaries explicit:

- the noticed task is already terminal
- the agent may append new work or emit follow-up user-visible output
- the agent may not rewrite the noticed task into success or re-open it in place
- the agent is not granted implicit authority to retry the original failed provider/kernel task in place; retry/abandon remains an explicit parent-side product decision
- deployment / transport / hook-contract failures are not deliverable as task notices because the callback channel itself is not trustworthy in those cases

### Subagent Result Exchange

Parent-side subagent orchestration needs an explicit exchanged schema as well.

At minimum, subagent result payloads should distinguish:

- `subagent_id`
- `status`
- optional structured `result`
- optional `artifacts`
- optional `assistant_output_candidate`
- optional bounded `error`
- lifecycle metadata such as `started_at`, `finished_at`, `timed_out`, or `wait_status`

`assistant_output_candidate` should itself be documented as a typed payload, for example:

- `format`
- `content`
- optional `scope = partial | full`

The schema contract should make these boundaries explicit:

- subagent result payloads are parent-consumable join inputs
- they are not direct transcript mutations
- they are not child-conversation transcript authority
- only the parent step may convert aggregated candidate material into final output through `emit_message`

### Hook Action Envelope

Hook results should use an action envelope of the form:

```json
{
  "planning": {
    "step_plan": {
      "summary": "inspect the request and choose the next execution strategy"
    },
    "staged_mutations": {
      "prompt_buffer_ops": [
        {
          "op": "put",
          "buffer_name": "system",
          "content": "..."
        }
      ]
    },
    "tool_surface": {
      "capability_registry_snapshot_id": "cap_123",
      "selected_tool_ids": ["tool_abc"],
      "tool_surface_label": "default"
    },
    "planned_tasks": []
  },
  "actions": [
    {
      "type": "set_step_status",
      "text": "processing",
      "state": "running"
    }
  ]
}
```

Only planning-phase `before_agent_step` should return `planning`.
Other hooks should return the same envelope shape with `actions[]` only.

In V1:

- control hooks use this envelope to steer a live step
- terminal notice hooks use the same envelope shape for follow-up work after terminal task outcomes
- terminal notice hooks are append-only for `create_task`
- no runtime hook acts as a generic kernel/provider error catcher

Multiple `create_task` actions in one envelope are valid and are the expected way to express multi-subagent fanout from hooks.

The validator should reject:

- unknown top-level keys
- `planning` returned from non-planning hooks
- direct `approval_state` mutation from agent hooks
- `create_task` payloads that attempt to specify routed implementation ids
- `emit_message` followed by `set_step_status` or a second `emit_message`
- terminal actions that are not tail-only
- `set_step_status` in contexts where no current placeholder exists
- contract failures that should stay fail-fast instead of recursively dispatching runtime hooks

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
