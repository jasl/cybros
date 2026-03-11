# Agent Hooks Capabilities Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** fully cut the programmable-agent runtime over to typed hooks, cached capability snapshots, per-step tool-surface manifests, unified execution context, and lane-buffer-backed prompt building.

**Architecture:** build on the new lane-state / prompt-buffer substrate and the completed context-budget rewrite. Keep Cybros as the sole authority for DAG mutation, routing, policy, and telemetry while letting the agent program own prompt construction, hook decisions, tool-surface selection, and agent-contributed tool implementations. This is a destructive runtime cutover: active code and active docs should end up speaking this model only. What remains deferred is choosing and proving one production-grade concrete agent strategy.

**Tech Stack:** Rails 8.2 alpha, Ruby 4.0.1, existing AgentCore DAG runtime, Cybros programmable-agent runtime surfaces, Minitest.

---

## Cross-Plan Dependencies

- `2026-03-11-lane-state-prompt-buffer.md` must land first.
- `2026-03-11-context-budget-soft-limit.md` must land first.

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
- hook and tool payloads never relying on ambient globals

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
- staged settings/config/lane-state mutation still commits only at finalization
- execution-target proposal still works during the planning phase
- approval resume still does not replay the same planning work
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
- `on_hardcap_reached`
- `before_subagent_spawn`
- `after_subagent_result`
- `before_finalize_output`
- `on_tool_error`
- `on_subagent_error`
- `on_context_recovery_error`
- `on_runtime_error`
- actions:
  - `noop`
  - `emit_message`
  - `create_task`
  - `halt`
  - `deny`
- ordered `actions[]` envelope instead of a single scalar intent
- `create_task.placement = prepend | append`
- `prepend = defer + run + resume`
- multiple `create_task` actions from one hook invocation
- terminal actions (`halt` / `deny`) validated as tail-only actions
- startup / deployment / contract failures remain fail-fast and do not dispatch runtime error hooks
- specific loop/conversation error hooks take precedence over the fallback runtime error hook
- migration of bundled default agent logic away from legacy `turn.prepare` / `turn.compose` / `turn.handle_error` as canonical runtime hooks, preserving user-visible failure feedback through the new scoped error hooks

**Verify with:**

`bin/rails test test/integration/programmable_agent_hooks_test.rb test/integration/programmable_agent_error_hooks_test.rb test/scenarios/dag/programmable_agent_prepend_resume_test.rb`

### Task 8: Replace Child-Conversation Subagent Semantics In The Active Runtime

**Files:**

- modify kernel-owned `subagent_*` runtime/tool surfaces
- update active subagent docs and runtime public API docs
- update subagent tests that currently assume child-conversation semantics

**Must cover:**

- subagents modeled as background agent threads in the programmable-agent runtime
- removal of active child-conversation semantics from programmable-agent surfaces
- no active contradiction between `docs/agent_core/public_api.md`, `docs/dag/subagent_patterns.md`, and this runtime plan

**Verify with:**

`bin/rails test test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/scenarios/dag/subagent_tools_profile_enforcement_flow_test.rb`

### Task 9: Model Subagent Fanout/Fan-In As Explicit Parent-Side Tasks

**Files:**

- modify programmable-agent runtime docs / contracts for subagent semantics
- update bundled/default agent behavior where subagent fanout is exercised
- add scenario tests covering multi-subagent action envelopes and aggregation tasks

**Must cover:**

- subagents as background agent threads rather than default child conversations
- no reliance on `merge_lane_state` for subagent fan-in
- parent-side explicit aggregation tasks such as result collection / synthesis
- hook-produced multi-task fanout for subagent work

**Verify with:**

`bin/rails test test/scenarios/dag/programmable_agent_subagent_fanout_test.rb test/scenarios/dag/programmable_agent_subagent_aggregation_test.rb`

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

**Must cover:**

- hooks as typed code callbacks
- capabilities handshake / refresh
- tool-surface manifests
- unified execution context
- lane-prompt-buffer-backed prompt building
- `cybros_*` reserved namespace
- agent-priority routing for non-`cybros_*`
- `actions[]` hook envelopes
- subagent background-thread semantics and explicit parent-side aggregation
- no old `conversation.kv.*` / old prompt-working-set story in active docs
- no active doc describing execution-time fallback lookup as the programmable-agent routing model
- no active doc describing old programmable-agent runtime concepts as still canonical
- no active doc presenting bundled default `turn.prepare` / `turn.compose` / `turn.handle_error` as the canonical programmable-agent surface unless they are explicitly retained in the new model
- no active doc retaining child-conversation subagent semantics for programmable-agent runtime
- explicit alignment of:
  - `docs/product/agent_rpc.md`
  - `docs/product/run_lifecycle.md`
  - `docs/product/programmable_agents.md`
  - `docs/agent_core/public_api.md`
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
- capability snapshots and refresh work
- tool-surface manifest routing works
- telemetry dimensions exist
- no active docs or code imply the old model
- bundled default agent is running on the new runtime contract surface
- legacy bundled-default runtime methods are removed unless explicitly retained by the new model
- explicitly note that concrete-agent quality proof is still deferred, while runtime cutover is complete

**Verify with:**

`bin/rails test test/lib/cybros/programmable_agent test/integration/programmable_agent_*_test.rb test/lib/agent_core/dag/prompt_assembly_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb test/scenarios/dag/programmable_agent_prepend_resume_test.rb test/scenarios/dag/programmable_agent_subagent_fanout_test.rb test/scenarios/dag/programmable_agent_subagent_aggregation_test.rb test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb`

`rg -n "conversation\\.kv|ConversationKVEntry|tool fallback|runtime registry lookup|legacy prompt working set|old prompt-working-set|fallback lookup|unregistered agent tool|legacy programmable-agent runtime|turn\\.prepare|turn\\.compose|turn\\.handle_error|child conversation|child_conversation" cybros/app cybros/lib cybros/docs cybros/agents/default --glob '!archive/**'`
