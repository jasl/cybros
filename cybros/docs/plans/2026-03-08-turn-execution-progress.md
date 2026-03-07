# Turn Execution Progress Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the narrow tool-progress contract with a turn-scoped execution model built on `turn_execution + activities[]`, projected into assistant bubbles as `run_state`, with strong observability, debug export support, and eventual first-class subagent activity modeling while keeping subagents as independent conversations/graphs.

**Architecture:** Reuse DAG nodes, `turn_id`, task-side planning input, task state, and node events as durable truth. Add a turn-execution projector in the App layer, emit structured activity lifecycle events from execution paths, and move the UI from tool-specific text progress to activity-aware projections. Treat `turn_execution` as both the product-facing execution read model and the concise execution log surface, with explicit debug-mode diagnostics and an internal export surface that feeds the existing DAG debug CLI. Keep historical cleanup policy out of the first implementation as long as completed-turn execution history remains safely disposable. Harden subagent support in parallel so parent-visible subagent activities can rely on stable worker and orchestration semantics.

**Tech Stack:** Ruby 4.0, Rails 8 alpha, ActiveSupport tests, DAG engine (`DAG::Graph`, `DAG::Node`, `DAG::Runner`, `DAG::TranscriptProjection`), AgentCore executors, ActionCable `ConversationChannel`, Stimulus frontend controller, Turbo Streams.

## Scope

This plan is intentionally split into two milestones:

- **Milestone 1:** turn execution projector + same-conversation activity progress + baseline observability/debug support + parent-side subagent calls surfaced only as ordinary task activities
- **Milestone 2:** formal subagent worker/orchestration primitives (`subagent_run` / `subagent_wait`) + parent-visible child status snapshots + first-class `kind = "subagent"` projection

The plan is designed so Milestone 1 is independently shippable, but Milestone 2 is included here because it is part of the chosen target architecture.

Because this execution layer is mostly behind the scenes, automated coverage and diagnosability are first-class deliverables, not cleanup work.

Automatic cleanup of old completed execution diagnostics is explicitly deferred to a later app-level operational policy.

## Execution posture

This plan assumes an experimental delivery mode:

- breaking changes are allowed
- backward compatibility with earlier tool-progress drafts or transient local data is not required
- database reset / clearing local data is acceptable if it simplifies the architecture or implementation
- do not spend effort on compatibility shims unless they directly reduce implementation risk

## Execution order and dependency constraints

Recommended order:

1. Task 1 (`freeze canonical turn execution contract`)
2. Task 2 (`turn execution projector core`)
3. Task 3 (`structured activity lifecycle events`)
4. Task 4 (`execution observability and debug-mode diagnostics`)
5. Task 5 (`message projection and refresh wiring`)
6. Task 6 (`assistant bubble activity UI`)
7. Task 7 (`replay and reconnect hardening`)
8. Task 8 (`internal debug export surface and DAG debug CLI integration`)
9. Task 9 (`harden subagent worker boundary`)
10. Task 10 (`introduce subagent_run / subagent_wait`)
11. Task 11 (`integrate subagent activities into turn execution`)
12. Task 12 (`final verification and doc cleanup`)

Hard dependencies:

- Task 1 must land before everything else.
- Task 2 must land before Tasks 4, 5, 6, 7, 8, and 11.
- Task 3 must land before Tasks 4, 5, 6, 7, 8, and 11 because observability, UI, replay, and debug export all depend on structured activity facts.
- Task 4 must land before Tasks 5, 6, 7, 8, and 11 because the app-facing reads and debugging surfaces need stable diagnostic fields.
- Task 5 must land before Task 6 because the UI must consume stable app-facing reads, not bespoke client-side aggregation.
- Task 7 must land before Tasks 8 and 12 so debug export and verification run against the real replay/refresh contract.
- Task 8 must land before Task 12 so verification covers non-bubble diagnostic access.
- Task 9 must land before Task 10 because parent-facing subagent orchestration should build on a stable worker boundary.
- Task 10 must land before Task 11 because parent-visible subagent activities need higher-level orchestration anchors.

## Acceptance criteria

This plan is complete only when all of the following are true:

- `turn_execution + activities[]` is the single canonical execution contract
- `agent_message.run_state` is derived from `turn_execution`, not maintained as a separate truth store
- `standard` and `debug` produce the same canonical activity identity and status reduction for the same turn
- debug data is observation-only and does not widen permissions or alter execution flow
- replay, refresh, reconnect, and missed-event recovery converge from durable truth without relying on prior cable delivery
- the existing DAG debug CLI can export turn execution diagnostics outside the assistant bubble
- subagents remain independent conversations/graphs throughout implementation
- Milestone 1 does not mirror child-internal execution into the parent surface
- Milestone 2 introduces first-class parent-visible `kind = "subagent"` projection only after worker/orchestration primitives exist
- the focused tests added across the tasks are green
- broader regression checks around channel replay and subagent policy/tool flows are green

---

## Task 1: Freeze the canonical `turn_execution + activities[]` contract

### Task 1 Files

- Modify: `docs/plans/2026-03-08-turn-execution-progress-design.md`
- Modify: this plan

### Task 1 / Step 1: Write the contract examples

Add explicit examples for:

- `turn_execution.status`
- `turn_execution.diagnostic_level` and `event_cursor`
- `activities[*].kind`
- `activities[*].status`
- per-activity ordering / diagnostic fields
- `agent_message.run_state`
- `visibility` rules (`assistant_bubble`, `composer_only`)

### Task 1 / Step 2: Re-read the adjacent boundaries

Review and cross-check:

- `docs/plans/2026-03-07-conversation-input-policies-design.md`
- `docs/plans/2026-03-07-dag-debug-cli-design.md`
- `docs/plans/2026-03-08-agent-runtime-surface-design.md`
- `docs/dag/subagent_patterns.md`

Expected: no unresolved ambiguity remains about bubble vs composer vs child-conversation scope.

### Task 1 / Step 3: Write the final wording

Make the docs explicitly freeze:

- same-turn projector scope
- parent-visible subagent scope
- Milestone 1 parent-side subagent calls remain ordinary task activities
- no child-internal mirroring in Milestone 1
- debug-mode and cleanup boundaries (`standard` vs `debug`, what later cleanup may remove)
- `turn_execution` remains consumable by debug tooling outside the assistant bubble
- exact cleanup policy and TTLs are non-blocking operational choices, not architecture blockers

### Task 1 / Step 4: Commit

```bash
git add cybros/docs/plans/2026-03-08-turn-execution-progress-design.md cybros/docs/plans/2026-03-08-turn-execution-progress.md
git commit -m "docs: freeze turn execution progress contract"
```

## Task 2: Add the turn execution projector core

### Task 2 Files

- Create: `cybros/app/models/conversation/turn_execution_projector.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/lib/dag/transcript_projection.rb`
- Test: create `cybros/test/models/conversation/turn_execution_projector_test.rb`
- Test: create `cybros/test/models/conversation/turn_execution_projection_visibility_test.rb`

### Task 2 / Step 1: Write the failing tests

Add tests that prove:

- a `turn_id` can be projected into one `turn_execution`
- descendant same-turn tasks become `activities[]`
- preflight tasks can exist in the same execution object without entering the bubble projection
- projected activity ordering is stable enough to act as a concise execution timeline
- `message_for_node_id` can derive `run_state` from the projector rather than local UI assumptions

### Task 2 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/models/conversation/turn_execution_projector_test.rb test/models/conversation/turn_execution_projection_visibility_test.rb
```

Expected: FAIL because no turn-execution projector exists yet.

### Task 2 / Step 3: Write minimal implementation

Implement `Conversation::TurnExecutionProjector` that:

- groups same-turn nodes by `turn_id`
- maps same-turn `task` nodes to activity hashes
- computes turn status/phase from node states
- computes stable activity ordering / cursor-friendly summary fields
- exposes assistant-bubble-visible activity subsets

Wire it into `Conversation` with read helpers such as:

- `turn_execution_for_turn_id`
- `turn_execution_for_node_id`

Keep the projector read-only and derived from DAG truth.

### Task 2 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 2 / Step 5: Commit

```bash
git add cybros/app/models/conversation/turn_execution_projector.rb cybros/app/models/conversation.rb cybros/lib/dag/transcript_projection.rb cybros/test/models/conversation/turn_execution_projector_test.rb cybros/test/models/conversation/turn_execution_projection_visibility_test.rb
git commit -m "feat: add turn execution projector"
```

## Task 3: Emit structured `activity_*` lifecycle events

### Task 3 Files

- Modify: `cybros/lib/dag/node_event_stream.rb`
- Modify: `cybros/app/models/dag/node_event.rb`
- Modify: `cybros/lib/agent_core/dag/executors/task_executor.rb`
- Possibly modify: `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Test: create `cybros/test/lib/dag/node_event_stream_activity_test.rb`
- Test: create `cybros/test/lib/agent_core/dag/task_executor_activity_events_test.rb`

### Task 3 / Step 1: Write the failing tests

Add tests that assert:

- task execution emits structured `activity_started`
- task completion emits structured `activity_finished`
- task errors emit structured `activity_failed`
- planning/binding can emit `activity_planned` or `activity_waiting`
- payloads are machine-readable and include `event_id`, `turn_id`, `sequence`, `activity_id`, `kind`, `status`, `phase`, `source_node_id`, and `diagnostic_level`

### Task 3 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/lib/dag/node_event_stream_activity_test.rb test/lib/agent_core/dag/task_executor_activity_events_test.rb
```

Expected: FAIL because only `progress/log/output_delta` exist today and task execution ignores `stream:`.

### Task 3 / Step 3: Write minimal implementation

Extend node events and task execution so:

- `output_delta` remains for assistant text streaming
- execution progress uses structured `activity_*` events
- each activity event carries ordering/correlation facts for replay debugging
- the payload shape is generic enough for future `subagent` and `preflight_task` activities

Do not yet add child-conversation event bridging.

### Task 3 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 3 / Step 5: Commit

```bash
git add cybros/lib/dag/node_event_stream.rb cybros/app/models/dag/node_event.rb cybros/lib/agent_core/dag/executors/task_executor.rb cybros/lib/agent_core/dag/executors/agent_message_executor.rb cybros/test/lib/dag/node_event_stream_activity_test.rb cybros/test/lib/agent_core/dag/task_executor_activity_events_test.rb
git commit -m "feat: emit structured activity lifecycle events"
```

## Task 4: Add execution observability and debug-mode diagnostics

### Task 4 Files

- Modify: `cybros/app/models/conversation_run.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Modify: `cybros/app/channels/conversation_channel.rb`
- Possibly modify: `cybros/app/controllers/conversation_messages_controller.rb`
- Possibly modify: `cybros/app/controllers/conversations_controller.rb`
- Test: create `cybros/test/models/conversation/turn_execution_debug_mode_test.rb`
- Test: create `cybros/test/channels/conversation_channel_activity_sequence_test.rb`

### Task 4 / Step 1: Write the failing tests

Add coverage that proves:

- projected `turn_execution` exposes stable ordering / cursor fields for debugging missed events
- `standard` mode retains concise diagnostics only
- `debug` mode exposes richer diagnostic details without changing canonical activity identity
- `standard` and `debug` keep the same `activity_id` / `kind` / `status` / `phase` / ordering for the same turn
- the diagnostic-level switch can be set through an internal-only execution flag on turn creation/retry paths
- replay/debugging can explain ordering gaps without relying on raw text logs

### Task 4 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/models/conversation/turn_execution_debug_mode_test.rb test/channels/conversation_channel_activity_sequence_test.rb
```

Expected: FAIL because turn execution currently has no explicit debug-mode or activity-sequencing contract.

### Task 4 / Step 3: Write minimal implementation

Add observability plumbing so:

- turn-scoped diagnostic level is durably stored on the anchor agent node or equivalent turn-owned metadata
- `ConversationRun.debug` may mirror the same flag for operator-facing bookkeeping, but projector truth does not depend only on that mirror
- projected `turn_execution` exposes `diagnostic_level`, `event_cursor`, and activity ordering fields
- channel payloads include correlation/ordering data that help explain missed-event behavior
- default `standard` mode stays compact, while `debug` adds richer diagnostic fields
- `debug` stays observation-only and does not alter execution decisions, activity identity, or permissions
- first-pass activation remains internal-only; no end-user debug toggle is required here

Keep this internal-facing first; do not design a public end-user debug UX here.

### Task 4 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 4 / Step 5: Commit

```bash
git add cybros/app/models/conversation_run.rb cybros/app/models/conversation.rb cybros/app/models/conversation/turn_execution_projector.rb cybros/app/channels/conversation_channel.rb cybros/app/controllers/conversation_messages_controller.rb cybros/app/controllers/conversations_controller.rb cybros/test/models/conversation/turn_execution_debug_mode_test.rb cybros/test/channels/conversation_channel_activity_sequence_test.rb
git commit -m "feat: add execution observability and debug diagnostics"
```

## Task 5: Expose `turn_execution` and `run_state` in app-facing reads

### Task 5 Files

- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/lib/dag/transcript_projection.rb`
- Test: create `cybros/test/models/conversation/message_run_state_projection_test.rb`
- Test: create `cybros/test/integration/conversation_messages_refresh_execution_test.rb`

### Task 5 / Step 1: Write the failing tests

Add coverage that proves:

- `Conversation#message_for_node_id` returns a `run_state` derived from `turn_execution`
- `Conversation#message_page` includes `run_state` for running assistant bubbles
- `messages/refresh` reconstructs the same execution state without prior cable history
- projected `run_state` carries the bounded diagnostic summary needed for debugging hidden execution flows

### Task 5 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/models/conversation/message_run_state_projection_test.rb test/integration/conversation_messages_refresh_execution_test.rb
```

Expected: FAIL because current message projection does not expose turn execution.

### Task 5 / Step 3: Write minimal implementation

Project `turn_execution` into `agent_message.run_state`:

- use assistant-bubble-visible activities only
- keep terminal markdown rendering behavior intact
- include bounded execution summary / diagnostics fields
- keep the underlying `turn_execution` read reusable for debug CLI / internal inspection
- avoid client-side aggregation of task state

### Task 5 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 5 / Step 5: Commit

```bash
git add cybros/app/models/conversation.rb cybros/lib/dag/transcript_projection.rb cybros/test/models/conversation/message_run_state_projection_test.rb cybros/test/integration/conversation_messages_refresh_execution_test.rb
git commit -m "feat: expose turn execution in message projections"
```

## Task 6: Replace the bubble UI with activity-aware execution rendering

### Task 6 Files

- Modify: `cybros/app/views/conversation_messages/_message.html.erb`
- Create: `cybros/app/views/conversation_messages/_run_state.html.erb`
- Modify: `cybros/app/javascript/controllers/conversation_channel_controller.js`
- Test: create `cybros/test/integration/conversation_execution_progress_ui_test.rb`
- Test: create `cybros/test/e2e/conversation_execution_progress.spec.ts`

### Task 6 / Step 1: Write the failing tests

Add coverage that asserts:

- a running assistant bubble renders a structured execution block
- multiple activities can be shown at once
- assistant text streaming and activity streaming coexist
- bounded diagnostic summaries are available for hidden execution failures
- terminal convergence collapses back to ordinary final output

### Task 6 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/integration/conversation_execution_progress_ui_test.rb
bin/rails test test/channels/conversation_channel_test.rb
```

Expected: FAIL because the bubble still assumes one hidden progress line and text span.

### Task 6 / Step 3: Write minimal implementation

Replace the old bubble progress strip with:

- top-level execution summary
- compact `activities[]` list
- bounded diagnostic context for failures / waits
- assistant text body
- graceful terminal collapse

Keep `message_<node_id>` as the durable wrapper unit.

### Task 6 / Step 4: Run tests to verify they pass

Run the same test commands again, plus the focused E2E if available.

Expected: PASS

### Task 6 / Step 5: Commit

```bash
git add cybros/app/views/conversation_messages/_message.html.erb cybros/app/views/conversation_messages/_run_state.html.erb cybros/app/javascript/controllers/conversation_channel_controller.js cybros/test/integration/conversation_execution_progress_ui_test.rb cybros/test/e2e/conversation_execution_progress.spec.ts cybros/test/channels/conversation_channel_test.rb
git commit -m "feat: render activity-based execution progress in assistant bubbles"
```

## Task 7: Harden replay, reconnect, and terminal convergence

### Task 7 Files

- Modify: `cybros/app/channels/conversation_channel.rb`
- Modify: `cybros/app/controllers/conversation_messages_controller.rb`
- Modify: `cybros/app/models/conversation.rb`
- Test: create `cybros/test/channels/conversation_channel_execution_replay_test.rb`
- Test: create `cybros/test/integration/conversation_execution_reconnect_test.rb`

### Task 7 / Step 1: Write the failing tests

Add coverage for:

- replay of structured `activity_*` events
- reconnect after missed activity events
- `messages/refresh` convergence from durable truth
- stale replay after turn interruption/steer being ignored correctly
- replay/debugging remains explainable via activity sequence/cursor data

### Task 7 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/channels/conversation_channel_execution_replay_test.rb test/integration/conversation_execution_reconnect_test.rb
```

Expected: FAIL because replay still assumes `progress/log/output_delta`.

### Task 7 / Step 3: Write minimal implementation

Update the channel contract so:

- replay batches carry structured activity payloads
- `event.text` is no longer execution truth
- cursor/sequence metadata survives replay
- refresh remains the fallback truth path

### Task 7 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 7 / Step 5: Commit

```bash
git add cybros/app/channels/conversation_channel.rb cybros/app/controllers/conversation_messages_controller.rb cybros/app/models/conversation.rb cybros/test/channels/conversation_channel_execution_replay_test.rb cybros/test/integration/conversation_execution_reconnect_test.rb
git commit -m "feat: harden execution progress replay and refresh"
```

## Task 8: Add an internal debug export surface and wire it into DAG debug CLI

### Task 8 Files

- Modify: `cybros/lib/cybros/cli/dag_debug.rb`
- Modify: `cybros/script/dag_debug.rb`
- Modify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Possibly create: `cybros/app/controllers/internal/turn_executions_controller.rb`
- Test: extend `cybros/test/lib/cybros/debug/dag_debug_test.rb`
- Test: extend `cybros/test/lib/cybros/debug/dag_debug_cli_format_test.rb`
- Test: extend `cybros/test/lib/cybros/debug/dag_debug_command_status_test.rb`

### Task 8 / Step 1: Write the failing tests

Add tests that prove:

- `turn_execution` can be exported outside the assistant bubble
- the existing DAG debug CLI can render or emit structured execution diagnostics for a target turn/node
- debug-mode fields appear in export output without changing canonical activity identity
- export remains useful after reconnect/replay-sensitive turns because it rebuilds from durable truth

### Task 8 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/debug/dag_debug_test.rb test/lib/cybros/debug/dag_debug_cli_format_test.rb test/lib/cybros/debug/dag_debug_command_status_test.rb
```

Expected: FAIL because the debug CLI does not yet expose `turn_execution` diagnostics.

### Task 8 / Step 3: Write minimal implementation

Add a reusable export surface for `turn_execution` diagnostics and wire it into the existing DAG debug tooling:

- expose turn execution snapshots in a helper or internal endpoint
- make `script/dag_debug.rb` consume that export for human and JSON output
- keep the CLI thin and the export logic testable in Ruby
- do not build a full Web UI debugger here

### Task 8 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 8 / Step 5: Commit

```bash
git add cybros/lib/cybros/cli/dag_debug.rb cybros/script/dag_debug.rb cybros/app/models/conversation/turn_execution_projector.rb cybros/app/controllers/internal/turn_executions_controller.rb cybros/test/lib/cybros/debug/dag_debug_test.rb cybros/test/lib/cybros/debug/dag_debug_cli_format_test.rb cybros/test/lib/cybros/debug/dag_debug_command_status_test.rb
git commit -m "feat: export turn execution diagnostics to dag debug cli"
```

## Task 9: Harden the subagent worker boundary

### Task 9 Files

- Modify: `cybros/lib/cybros/agent_profiles.rb`
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/docs/dag/subagent_patterns.md`
- Modify: `cybros/docs/agent_core/security.md`
- Test: extend `cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`
- Test: extend `cybros/test/scenarios/dag/subagent_tools_profile_enforcement_flow_test.rb`

### Task 9 / Step 1: Write the failing tests

Add tests that prove:

- `subagent` no longer auto-inherits `memory_*` / `skills_*` allow behavior
- the subagent worker profile is genuinely minimal by default
- parent-facing coding/review profiles keep their expected behavior
- debug-mode diagnostics do not silently widen subagent permissions

### Task 9 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/scenarios/dag/subagent_tools_profile_enforcement_flow_test.rb
```

Expected: FAIL because phase 0 policy currently auto-allows `memory_*` / `skills_*` even for subagents.

### Task 9 / Step 3: Write minimal implementation

Adjust runtime policy composition so:

- the `subagent` worker profile is truly minimal by default
- phase 0 convenience auto-allow does not bypass the worker boundary
- diagnostic mode does not implicitly loosen tool policy
- docs reflect the new truth

### Task 9 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 9 / Step 5: Commit

```bash
git add cybros/lib/cybros/agent_profiles.rb cybros/lib/cybros/agent_runtime_resolver.rb cybros/docs/dag/subagent_patterns.md cybros/docs/agent_core/security.md cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb cybros/test/scenarios/dag/subagent_tools_profile_enforcement_flow_test.rb
git commit -m "feat: harden subagent worker policy boundary"
```

## Task 10: Introduce `subagent_run` and `subagent_wait`

### Task 10 Files

- Modify: `cybros/lib/cybros/subagent/tools.rb`
- Modify: `cybros/docs/agent_core/public_api.md`
- Modify: `cybros/docs/dag/subagent_patterns.md`
- Test: create `cybros/test/lib/cybros/subagent/run_wait_tools_test.rb`
- Test: extend `cybros/test/lib/cybros/subagent/tools_test.rb`

### Task 10 / Step 1: Write the failing tests

Add tests that prove:

- `subagent_run` performs spawn + child kick + initial status return
- `subagent_wait` returns a bounded child status snapshot with timeout-safe semantics
- nested-spawn and ownership constraints still hold
- the returned payload is stable enough for parent-side activity projection
- debug mode can be passed explicitly without changing the default narrow worker boundary

### Task 10 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/subagent/run_wait_tools_test.rb test/lib/cybros/subagent/tools_test.rb
```

Expected: FAIL because those tools do not exist yet.

### Task 10 / Step 3: Write minimal implementation

Add higher-level subagent orchestration tools:

- `subagent_run`
- `subagent_wait`

Keep `subagent_spawn` / `subagent_poll` as low-level primitives.

### Task 10 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 10 / Step 5: Commit

```bash
git add cybros/lib/cybros/subagent/tools.rb cybros/docs/agent_core/public_api.md cybros/docs/dag/subagent_patterns.md cybros/test/lib/cybros/subagent/run_wait_tools_test.rb cybros/test/lib/cybros/subagent/tools_test.rb
git commit -m "feat: add subagent run and wait tools"
```

## Task 11: Integrate parent-visible subagent activities into turn execution

### Task 11 Files

- Modify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/views/conversation_messages/_run_state.html.erb`
- Test: create `cybros/test/models/conversation/turn_execution_subagent_activity_test.rb`
- Test: create `cybros/test/integration/conversation_subagent_activity_ui_test.rb`

### Task 11 / Step 1: Write the failing tests

Add coverage that proves:

- parent-side `subagent_run` / `subagent_wait` tasks become `kind = "subagent"` activities
- the activity includes child ids and status snapshot fields
- the assistant bubble shows the subagent activity without showing child-internal task lists
- debug-enabled parent runs surface richer child snapshot diagnostics without changing the base activity shape

### Task 11 / Step 2: Run tests to verify they fail

Run:

```bash
cd cybros
bin/rails test test/models/conversation/turn_execution_subagent_activity_test.rb test/integration/conversation_subagent_activity_ui_test.rb
```

Expected: FAIL because the projector currently has no subagent-specific activity mapping.

### Task 11 / Step 3: Write minimal implementation

Extend the projector so parent-side subagent orchestration tasks map to:

- `kind = "subagent"`
- child link metadata
- parent-visible status snapshots
- optional debug-only diagnostic detail when enabled

Do not mirror child-internal execution activity lists yet.

### Task 11 / Step 4: Run tests to verify they pass

Run the same tests again.

Expected: PASS

### Task 11 / Step 5: Commit

```bash
git add cybros/app/models/conversation/turn_execution_projector.rb cybros/app/models/conversation.rb cybros/app/views/conversation_messages/_run_state.html.erb cybros/test/models/conversation/turn_execution_subagent_activity_test.rb cybros/test/integration/conversation_subagent_activity_ui_test.rb
git commit -m "feat: project parent-side subagent activities"
```

## Task 12: Final verification and cleanup

### Task 12 Files

- Verify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Verify: `cybros/app/models/conversation.rb`
- Verify: `cybros/app/models/conversation_run.rb`
- Verify: `cybros/lib/dag/transcript_projection.rb`
- Verify: `cybros/lib/dag/node_event_stream.rb`
- Verify: `cybros/lib/cybros/cli/dag_debug.rb`
- Verify: `cybros/script/dag_debug.rb`
- Verify: `cybros/lib/agent_core/dag/executors/task_executor.rb`
- Verify: `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Verify: `cybros/app/channels/conversation_channel.rb`
- Verify: `cybros/app/javascript/controllers/conversation_channel_controller.js`
- Verify: `cybros/app/views/conversation_messages/_message.html.erb`
- Verify: `cybros/app/views/conversation_messages/_run_state.html.erb`
- Verify: `cybros/lib/cybros/subagent/tools.rb`
- Verify: docs touched along the way

### Task 12 / Step 1: Run focused verification

Run the exact set of updated tests covering:

- projector core
- activity events
- debug-mode projection
- debug export / DAG debug CLI
- message projection
- replay/reconnect
- bubble UI
- subagent worker boundary
- subagent orchestration tools
- parent-side subagent activities

### Task 12 / Step 2: Run broader verification

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/subagent/tools_test.rb test/scenarios/dag/subagent_tools_profile_enforcement_flow_test.rb test/channels/conversation_channel_test.rb
```

and then the broader relevant scenario set if green.

### Task 12 / Step 3: Run targeted failure injection

Manually force and verify at least these paths through tests or fixtures:

- task error / timeout
- approval wait
- replay after missed events
- debug export after replay-sensitive execution
- stale or interrupted turn
- subagent timeout / ownership rejection
- `standard` vs `debug` diagnostic differences

### Task 12 / Step 4: Re-read the design

Confirm the implementation still matches the intended architecture:

- canonical object is `turn_execution`
- assistant bubble is a projection
- composer state stays separate
- subagents remain independent conversations/graphs
- child internals are still not mirrored into the parent execution surface
- `turn_execution` works as both execution read model and concise execution log surface

### Task 12 / Step 5: Commit

```bash
git add cybros
git commit -m "feat: complete turn execution progress architecture"
```
