# Agent Hooks Capabilities Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** fully cut the programmable-agent runtime over to typed hooks, cached capability snapshots, per-step tool-surface manifests, unified execution context, and lane-buffer-backed prompt building.

**Architecture:** build on the landed lane-state / prompt-buffer substrate and the landed context-budget rewrite. Keep Cybros as the sole authority for DAG mutation, routing, policy, and telemetry while letting the agent program own prompt construction, hook decisions, tool-surface selection, and agent-contributed tool implementations. This is a destructive runtime cutover: active code and active docs should end up speaking this model only. What remains deferred is choosing and proving one production-grade concrete agent strategy.

**Tech Stack:** Rails 8.2 alpha, Ruby 4.0.1, existing AgentCore DAG runtime, Cybros programmable-agent runtime surfaces, Minitest.

---

## Cross-Plan Dependencies

- The lane-state / prompt-buffer cut has already landed in code and its plan is archived under `docs/archive/plans/2026-03/2026-03-11-lane-state-prompt-buffer.md`.
- The context-budget rewrite has already landed in code and its plan is archived under `docs/archive/plans/2026-03/2026-03-11-context-budget-soft-limit.md`.
- This plan must treat those shipped substrates as the starting baseline rather than re-planning or re-introducing compatibility paths around them.

## Current Baseline

Before this plan starts, the codebase already ships:

- `lane.kv.*`
- `lane.prompt_buffer.*`
- `tokens.*`
- `merge_lane_state`
- `lane.prompt_buffer`-backed prompt assembly
- soft / hard context-budget logic on top of that substrate

What has **not** landed yet is the programmable-agent runtime cutover itself:

- bundled default agent still speaks `turn.prepare` / `turn.compose` / `turn.handle_error`
- planning still enters through `turn.prepare`
- active programmable-agent docs still describe the legacy turn-hook protocol as the shipped wire surface

This plan should therefore migrate the runtime **from that current baseline**, not repeat the already-completed lane-state/context-budget work.

## Destructive-Cut Assumptions

- breaking changes are allowed
- no compatibility shim is required
- database reset is allowed if needed
- old programmable-agent runtime concepts should remain only in archived docs after this plan lands

## Testing Posture

- schema / contract work begins with unit tests
- runtime routing work needs integration coverage
- prompt-builder and hook boundaries need scenario tests
- this round must fully switch the runtime substrate and remove superseded logic
- what it does not claim is that one ideal concrete agent implementation has already been proven
- `agents/default` is the required bundled reference agent for this cut and must be fully migrated, not left on a legacy RPC shape

### Task 1: Add Capability Snapshot And Tool-Surface Domain Objects

**Files:**

- create capability snapshot domain objects under `lib/cybros/programmable_agent/`
- modify runtime resolver / programmable-agent protocol contract objects
- test new objects under `test/lib/cybros/programmable_agent/`

**Must cover:**

- cached `capability_registry_snapshot_id`
- kernel catalog vs agent catalog merge
- reserved `cybros_*` namespace rejection
- default non-`cybros_*` agent-priority routing
- stable `tool_surface_id` derivation from selected tool ids

**Verify with:**

`bin/rails test test/lib/cybros/programmable_agent/capability_snapshot_test.rb test/lib/cybros/programmable_agent/tool_surface_manifest_test.rb`

### Task 2: Add Typed Session And Execution Context Contracts

**Files:**

- add typed `session_context` / `execution_context` contracts in programmable-agent runtime
- modify agent RPC payload builders / runtime resolver surfaces to supply them
- add tests under `test/lib/cybros/programmable_agent/` and integration coverage where payloads are built

**Must cover:**

- `account_id`
- `user_id`
- `conversation_id`
- `graph_id`
- `lane_id`
- `turn_id`
- `execution_scope = primary | subagent`
- `execution_context.subagent` with:
  - `subagent_id`
  - optional `parent_turn_id`
  - optional `parent_dag_node_id`
  - optional `depth`
- hook and tool payloads never relying on ambient globals
- agent code being able to distinguish the primary executor from a delegated subagent through typed execution context rather than legacy child-conversation inference

**Verify with:**

`bin/rails test test/lib/cybros/programmable_agent/execution_context_test.rb test/integration/programmable_agent_execution_context_test.rb`

### Task 3: Add Capability Handshake And Refresh Contracts

**Files:**

- modify programmable-agent RPC contracts / handlers for `capabilities.handshake`
- add `capabilities.refresh`
- update runtime resolver / deployment-side handshake callers
- add tests for unchanged vs refreshed paths

**Must cover:**

- cached handshake snapshots
- `kernel_capability_registry_version`
- refresh reasons: `kernel_registry_changed`, `agent_capabilities_changed`, `manual`
- unchanged response fast path
- refreshed snapshot path
- no execution-time fallback lookup against an unregistered agent tool implementation
- bundled default agent discovery moving onto this handshake path
- explicit coexistence with deployment inspection / activation methods:
  - `initialize`
  - `agent.describe`
  - `agent.health`
  - `agent.schemas.get`

**Verify with:**

`bin/rails test test/integration/programmable_agent_capabilities_handshake_test.rb test/integration/programmable_agent_capabilities_refresh_test.rb`

### Task 4: Remap Planning-Phase Runtime Semantics Off `turn.prepare`

**Files:**

- modify programmable-agent runtime docs / contracts for planning-phase behavior
- modify draft-planning orchestration and hook invocation boundaries
- update active product docs that still define `turn.prepare` as canonical
- add tests for staged mutation / approval resume under the new hook-driven surface

**Must cover:**

- `RunDraft` remains the durable planning object
- planning uses a typed `planning` envelope rather than legacy `prepared_plan`
- only `before_agent_step` in planning phase may return `planning`
- existing staged lane-state / prompt-buffer mutation semantics remain intact while the entry hook shape changes
- prompt-building inputs move through typed `staged_mutations.prompt_buffer_ops` rather than legacy prompt fragments
- staged mutation is represented through typed `staged_mutations` fields rather than side-effect-first planning callbacks
- staged settings/config/lane-state mutation still commits only at finalization
- execution-target proposal still works during the planning phase
- execution-target proposal is agent-suggested in `planning.execution_target_proposal` while kernel remains authoritative for the selected target
- approval resume still does not replay the same planning work
- agent hooks request approval through `planning.approval_request` while kernel remains authoritative for persisted `approval_state`
- work that must survive approval park / resume is persisted as `planning.planned_tasks`, not transient runtime actions
- removal of `turn.prepare` as the canonical programmable-agent planning RPC

**Verify with:**

`bin/rails test test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/programmable_agent_hooks_test.rb`

### Task 5: Add Per-Step Tool-Surface Manifest Submission And Validation

**Files:**

- add `tool_surface.manifest` contract
- wire manifest validation into the agent-step execution path
- update prompt-assembly / execution metadata paths
- add tests for manifest validation and stable ids

**Must cover:**

- `capability_registry_snapshot_id`
- `selected_tool_ids`
- optional `tool_surface_label`
- stable `tool_surface_id`
- rejection when selected ids are not in the snapshot
- validated tool surface acting as the step allowlist for both model-issued tool calls and hook-issued `create_task` actions

**Verify with:**

`bin/rails test test/lib/cybros/programmable_agent/tool_surface_manifest_test.rb test/lib/agent_core/dag/prompt_assembly_test.rb`

### Task 6: Route Tool Calls Through Snapshot-Based Effective Tools

**Files:**

- modify tool-call resolution in the programmable-agent execution path
- update task execution metadata
- update relevant resolver / runtime surface code
- add routing tests

**Must cover:**

- `logical_tool_name`
- `effective_tool_id`
- `implementation_ref`
- `implementation_source = kernel | agent_program`
- `cybros_*` staying reserved
- non-`cybros_*` names using agent-priority routing
- removal of superseded tool-routing assumptions from the active programmable-agent path

**Verify with:**

`bin/rails test test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/integration/programmable_agent_tool_routing_test.rb`

### Task 7: Add Typed Hook Entry Points And Intent Validation

**Files:**

- add hook contracts and validators under programmable-agent runtime
- wire hook invocation points into the Cybros loop
- add tests for typed payloads and intent handling

**Must cover:**

- `on_conversation_created`
- `before_agent_step`
- `on_context_pressure`
- `before_subagent_spawn`
- `after_task_notice`
- `after_subagent_result`
- `before_finalize_output`
- actions:
  - `noop`
  - `emit_message`
  - `set_step_status`
  - `create_task`
  - `halt`
  - `deny`
- ordered `actions[]` envelope instead of a single scalar intent
- hook-policy matrix enforcing which hooks may return `planning` and which action kinds are legal per hook
- validator split between envelope validation, planning validation, action-list validation, and hook-policy validation
- typed contract objects for the planning/action envelope rather than ad-hoc hashes in the runtime hot path
- validation error families under `hook_contract`, `hook_policy`, `hook_action`, and `runtime`
- orthogonal hook families:
  - planning/live-step control hooks for in-flight conversation control
  - terminal notice hooks for already-terminal task outcomes
  - fail-fast kernel paths that never dispatch runtime hooks
- `set_step_status` targeting only the current running step's placeholder / pending assistant bubble rather than arbitrary message mutation
- hook-driven placeholder progress updates such as `processing`, `compacting context`, or `waiting for subagent`
- `before_subagent_spawn` dispatching for the whole spawn-family (`subagent_spawn` and `subagent_run`), not only the raw `subagent_spawn` tool name
- `emit_message` finalizing the current placeholder rather than appending a second assistant transcript message for the same step
- `emit_message` forbidding later `set_step_status` or a second `emit_message` in the same envelope while still allowing explicit appended follow-up work
- `create_task.placement = prepend | append`
- `prepend = defer + run + resume`
- multiple `create_task` actions from one hook invocation
- `create_task` remaining a limited neighboring-task control surface rather than an API for rewriting the current materialized task
- terminal notice hooks limited to `create_task(append)` follow-up work rather than `prepend = defer + run + resume`
- terminal actions (`halt` / `deny`) validated as tail-only actions
- planning-phase `before_agent_step` restricted to `halt` but not `deny`, because pending agent placeholders have a clean stop transition but not a generic reject transition
- direct agent mutation of `approval_state` rejected in favor of `planning.approval_request`
- attempts to specify `effective_tool_id` / `implementation_ref` from hook-created tasks rejected as contract violations
- startup / deployment / transport / contract failures remain fail-fast and do not dispatch runtime hooks
- `after_task_notice` carrying typed terminal notice payloads for kernel/provider-managed task outcomes such as:
  - `provider_error`
  - `hardcap_reached`
  - `permission_denied`
  - `remote_tool_failed`
  - `remote_tool_timed_out`
  - `remote_tool_denied`
- explicit rule that agent-visible terminal notices are follow-up signals, not authority to rewrite the failed task into success
- explicit rule that retry/abandon of the original failed provider/kernel task remains a parent-side product decision rather than implicit agent hook authority
- migration of bundled default agent logic away from legacy `turn.prepare` / `turn.compose` / `turn.handle_error` as canonical runtime hooks, preserving user-visible failure feedback through the new control/notice hook split

**Verify with:**

`bin/rails test test/integration/programmable_agent_hooks_test.rb test/integration/programmable_agent_error_hooks_test.rb test/scenarios/dag/programmable_agent_prepend_resume_test.rb test/scenarios/dag/programmable_agent_step_status_placeholder_test.rb`

### Task 8: Replace Child-Conversation Subagent Semantics In The Active Runtime

**Files:**

- modify kernel-owned `subagent_*` runtime/tool surfaces
- modify execution projection / UI surfaces that currently project `child_conversation_id`
- modify statistics / reporting surfaces that currently encode subagent child-conversation scope
- update active subagent docs and runtime public API docs
- update subagent tests that currently assume child-conversation semantics

**Must cover:**

- subagents modeled as background agent threads in the programmable-agent runtime
- removal of active child-conversation semantics from programmable-agent surfaces
- explicit distinction between:
  - human-visible `conversation` / `child conversation` flows
  - non-interactive programmable-agent subagent runtime flows
- parent turn remains authoritative for placeholder, transcript, approval, and user-visible output
- no active contradiction between `docs/agent_core/public_api.md`, `docs/dag/subagent_patterns.md`, and this runtime plan

**Verify with:**

`bin/rails test test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/scenarios/dag/subagent_tools_profile_enforcement_flow_test.rb test/models/conversation/turn_execution_subagent_activity_test.rb test/integration/conversation_subagent_activity_ui_test.rb test/integration/statistics_page_subagent_scope_test.rb`

### Task 9: Model Subagent Fanout/Fan-In As Explicit Parent-Side Tasks

**Files:**

- modify programmable-agent runtime docs / contracts for subagent semantics
- update bundled/default agent behavior where subagent fanout is exercised
- update aggregation/projection layers that surface subagent results back into the parent turn
- add scenario tests covering multi-subagent action envelopes and aggregation tasks

**Must cover:**

- subagents as background agent threads rather than default child conversations
- no reliance on `merge_lane_state` for subagent fan-in
- parent-side explicit aggregation tasks such as result collection / synthesis
- hook-produced multi-task fanout for subagent work
- clear separation between durable `planning.planned_tasks` that survive resume and runtime `actions[].create_task` fanout that only affects the active execution flow
- subagent result schema carrying:
  - structured result data / artifacts
  - optional `assistant_output_candidate`
  - bounded lifecycle / error metadata
- parent-only authority for turning any `assistant_output_candidate` into final transcript output via the parent step
- tests proving subagent output candidates are aggregated by parent logic rather than directly appended as child-conversation transcript messages
- parent-visible execution projection and UI links updated to reflect runtime-owned subagent ids / task views rather than child-conversation ids
- statistics/reporting dimensions updated so subagent work remains auditable after the child-conversation model is removed

**Verify with:**

`bin/rails test test/scenarios/dag/programmable_agent_subagent_fanout_test.rb test/scenarios/dag/programmable_agent_subagent_aggregation_test.rb test/scenarios/dag/programmable_agent_subagent_output_candidate_test.rb`

### Task 10: Rebuild Bundled Agent Prompt Builder Around Lane State

**Files:**

- modify bundled/default programmable-agent prompt builder
- update context adapter / prompt assembly integration points as needed
- add tests for section sourcing and shrink order

**Must cover:**

- sections:
  - `system`
  - `developer`
  - `history`
  - `summaries`
  - `working_notes`
  - `handoff`
  - `memory`
  - `tools`
  - `budget_guidance`
- preserve the already-landed `lane.prompt_buffer` substrate rather than re-introducing conversation-global working memory or DAG-summary-only prompt assembly
- `summaries/working_notes/handoff` coming from `lane.prompt_buffer`
- shrink order preferring prompt buffer and tool surface before history
- removal of superseded prompt-working-set logic from the active programmable-agent path
- bundled default agent using this new prompt builder path rather than legacy prompt-fragment assembly

**Verify with:**

`bin/rails test test/lib/agent_core/dag/prompt_assembly_test.rb test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb test/integration/programmable_agent_prompt_builder_test.rb`

### Task 11: Add Telemetry And Reporting Dimensions For Agent-Contributed Tools

**Files:**

- extend task metadata / reporting surfaces
- update projections / reports that summarize tool execution
- add tests for reporting dimensions

**Must cover:**

- `capability_registry_snapshot_id`
- `kernel_capability_registry_version`
- `tool_surface_id`
- `tool_surface_label`
- `logical_tool_name`
- `implementation_source`
- `implementation_ref`
- `agent_program_id`
- `agent_program_version`
- `result_status`
- `latency_ms`

**Verify with:**

`bin/rails test test/scenarios/dag/agent_core_context_cost_report_test.rb test/integration/programmable_agent_tool_telemetry_test.rb`

### Task 12: Update Active Docs To The New Runtime Model

**Files:**

- modify active programmable-agent docs under `docs/agent_core/`
- modify product/runtime docs that still imply old agent-side capability handling
- archive any superseded planning docs if they conflict
- add or update active agent public API / schema reference docs for runtime payloads

**Must cover:**

- hooks as typed code callbacks
- capabilities handshake / refresh
- tool-surface manifests
- unified execution context
- explicit `execution_scope = primary | subagent`
- typed `execution_context.subagent`
- active documentation of the agent public API surface, including lifecycle methods vs runtime methods
- active documentation of request/response schemas for handshake, refresh, hook envelopes, tool execution callbacks, and tool-surface manifests
- active documentation of typed terminal task-notice and subagent-result exchange schemas
- field-level documentation of agent-authored vs kernel-authored vs derived/validated payload fields
- documentation of which payload fields are durable across approval park / resume versus step-local runtime fields
- validation/error semantics for malformed runtime envelopes and schema violations
- lane-prompt-buffer-backed prompt building
- `cybros_*` reserved namespace
- agent-priority routing for non-`cybros_*`
- `actions[]` hook envelopes
- planning-vs-actions authority split:
  - `planning` for durable step intent and staged mutation
  - `actions[]` for current-step runtime effects
  - kernel-owned `approval_state`, routing, placeholder identity, and transcript mutation
- hook-driven step-status placeholder updates on the current assistant bubble
- subagent background-thread semantics and explicit parent-side aggregation
- active documentation of subagent result exchange schemas, including structured results, artifacts, lifecycle metadata, and optional `assistant_output_candidate`
- explicit documentation that `assistant_output_candidate` is parent-owned draft material rather than transcript authority
- explicit documentation that provider/kernel task notices are follow-up notifications rather than agent-owned error recovery authority
- lifecycle-hook context rules, including which `execution_context` fields may be `nil` before a current step exists
- no old `conversation.kv.*` / old prompt-working-set story in active docs
- no active doc describing execution-time fallback lookup as the programmable-agent routing model
- no active doc describing old programmable-agent runtime concepts as still canonical
- no active doc presenting bundled default `turn.prepare` / `turn.compose` / `turn.handle_error` as the canonical programmable-agent surface unless they are explicitly retained in the new model
- no active doc retaining child-conversation subagent semantics for programmable-agent runtime
- once implementation is complete, archive this plan/design pair before final old-term grep so migration-language remnants live only under `docs/archive`
- explicit alignment of:
  - `docs/product/agent_rpc.md`
  - `docs/product/run_lifecycle.md`
  - `docs/product/programmable_agents.md`
  - `docs/agent_core/public_api.md`
  - `docs/agent_core/security.md`
  - active schema reference docs for agent/runtime payload exchange
  - `docs/dag/subagent_patterns.md`
  - superseded planning docs under `docs/plans/`

**Verify with:**

`rg -n "conversation\\.kv|ConversationKVEntry|tool fallback|runtime registry lookup|old prompt-working-set|legacy prompt working set|turn\\.prepare|turn\\.compose|turn\\.handle_error|child conversation|child_conversation" cybros/docs/agent_core cybros/docs/product cybros/docs/dag cybros/docs/plans --glob '!archive/**'`

### Task 13: Run Full Verification And Record Remaining Gaps

**Files:**

- no new files required
- update docs if verification uncovers contract drift

**Must cover:**

- lane-state-backed prompt building works
- typed hook contracts work
- planning-envelope persistence and approval resume work without replaying planning
- hook-driven placeholder status updates work against the current assistant bubble model
- `emit_message` replaces the placeholder rather than creating a second assistant transcript message for the same step
- capability snapshots and refresh work
- tool-surface manifest routing works
- telemetry dimensions exist
- no active docs or code imply the old model
- bundled default agent is running on the new runtime contract surface
- legacy bundled-default runtime methods are removed unless explicitly retained by the new model
- explicitly note that concrete-agent quality proof is still deferred, while runtime cutover is complete
- final grep runs only after this plan/design pair has been archived out of the active `docs/plans` surface

**Verify with:**

`bin/rails test test/lib/cybros/programmable_agent test/integration/programmable_agent_*_test.rb test/lib/agent_core/dag/prompt_assembly_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb test/scenarios/dag/programmable_agent_prepend_resume_test.rb test/scenarios/dag/programmable_agent_step_status_placeholder_test.rb test/scenarios/dag/programmable_agent_subagent_fanout_test.rb test/scenarios/dag/programmable_agent_subagent_aggregation_test.rb test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb`

`rg -n "conversation\\.kv|ConversationKVEntry|tool fallback|runtime registry lookup|legacy prompt working set|old prompt-working-set|fallback lookup|unregistered agent tool|legacy programmable-agent runtime|turn\\.prepare|turn\\.compose|turn\\.handle_error|child conversation|child_conversation" cybros/app cybros/lib cybros/docs cybros/agents/default --glob '!archive/**'`
