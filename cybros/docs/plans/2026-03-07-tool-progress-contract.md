# Tool Progress Contract Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Redesign Cybros tool progress around first-class durable task execution truth, a projected `run_state` on the parent assistant message, and a structured realtime contract that remains correct under refresh, reconnect, retry, and terminal convergence.

**Architecture:** Treat `task` nodes and task-scoped node events as the durable execution substrate. Build a new message-level `run_state` projector that derives the parent `agent_message` bubble’s running tool state from planning bindings, task states, task outputs, and durable events. Replace the weak `progress/log` text-only realtime contract with structured tool lifecycle payloads, but keep the default visible surface as the assistant bubble instead of exposing raw task rows by default.

**Tech Stack:** Ruby 4.0, Rails 8 alpha, ActiveSupport tests, DAG engine (`DAG::Graph`, `DAG::Node`, `DAG::Runner`, `DAG::TranscriptProjection`), AgentCore executors, ActionCable `ConversationChannel`, Stimulus frontend controller, Turbo Streams.

## Status

This plan should be treated as **blocked pending `Conversation Input Policies` landing**.

It should not be executed yet because several interface boundaries need the input-policies implementation to settle first:

- superseded / interrupted node transcript semantics
- `messages/refresh` behavior for hidden or superseded nodes
- queue / steer / candidate-input composer state
- whether preflight tasks remain separate from assistant-bubble `run_state`

## Unresolved questions to revisit before implementation

- Is `run_state` permanently assistant-bubble scoped, or do we eventually want a broader turn-level execution contract?
- What replay invalidation rule applies after `interrupt_new_turn` or `steer_current_turn`?
- What retention/coalescing/indexing strategy should structured `tool_*` events use?
- Which preview fields need default redaction/truncation rules (`arguments_preview`, `output_preview`, logs)?
- Does the first pass intentionally stop at lifecycle milestones, or do we also commit to fine-grained task log/progress streaming?

## Execution order and dependency constraints

Recommended order:

1. Task 0 (`freeze cross-plan boundaries after input policies`)
2. Task 1 (`planning -> task binding canonical truth`)
3. Task 2 (`replay scope and event scoping`)
4. Task 3 (`task execution lifecycle events`)
5. Task 4 (`run_state projection model`)
6. Task 5 (`message projection reset`)
7. Task 6 (`realtime contract reset`)
8. Task 7 (`assistant bubble UI reset`)
9. Task 8 (`replay/refresh durability hardening`)
10. Task 9 (`final verification`)

Hard dependencies:

- Task 0 must land before everything else.
- Task 1 must land before Tasks 3, 4, 5, and 6.
- Task 2 must land before Tasks 6, 7, and 8 because transport and UI must know the replay/refresh identity before implementation.
- Task 3 must land before Tasks 4 and 5 because the projector depends on durable lifecycle facts.
- Task 4 must land before Tasks 5, 6, and 7 because the projected `run_state` shape is the app-facing truth.
- Task 6 must land before Task 8 so replay and refresh can be verified against the real structured contract.

---

## Task 0: Freeze cross-plan boundaries after input policies land

### Task 0 Files

- Review after landing: `docs/plans/2026-03-07-conversation-input-policies-design.md`
- Review after landing: `docs/plans/2026-03-07-conversation-input-policies.md`
- Modify: this plan and `2026-03-07-tool-progress-contract-design.md`

### Task 0 / Step 1: Reconcile shared boundaries

Before implementation starts, explicitly freeze:

- whether `run_state` is assistant-bubble scoped only
- whether preflight tasks such as `compress_input` / `compact_context` stay outside `run_state`
- what `messages/refresh` returns for superseded/interrupted/hidden nodes
- what replay invalidation rule applies after `interrupt_new_turn` or `steer_current_turn`

### Task 0 / Step 2: Update this plan

Rewrite any still-ambiguous parts of this plan against the landed input-policies code and docs.

Expected: this plan becomes implementation-ready only after Task 0 is done.

## Task 1: Introduce a stable planning/binding contract between tool calls and task nodes

### Task 1 Files

- Modify: `lib/agent_core/dag/executors/agent_message_executor.rb`
- Modify: `app/models/messages/task.rb`
- Modify: `app/models/conversation.rb`
- Test: add scenario or executor-focused coverage under `test/scenarios/dag/` and/or `test/lib/agent_core/dag/`

### Task 1 / Step 1: Write the failing test

Add coverage that asserts:

- every tool call emitted by the assistant gets a stable `tool_call_id`
- every tool call is durably bound to a created `task_node_id`
- the binding survives replay and final message projection

### Task 1 / Step 2: Run test to verify it fails

Run the new planning/binding tests.

Expected: FAIL because current code creates tasks but does not expose a clean durable binding contract for projection.

### Task 1 / Step 3: Write minimal implementation

Make the planning expansion path produce durable binding facts that the projector can consume.

Canonical binding truth should live on the task side:

- `task.body.input`
- task state
- task output / preview

Parent agent metadata may keep coarse summaries only, and durable node events should remain temporal facts rather than a second canonical store.

### Task 1 / Step 4: Run test to verify it passes

Run the planning/binding tests again.

Expected: PASS

## Task 2: Define replay scope and event scoping

### Task 2 Files

- Modify: `app/channels/conversation_channel.rb`
- Modify: `app/models/conversation.rb`
- Modify: `lib/dag/transcript_projection.rb`
- Test: replay/refresh scope coverage

### Task 2 / Step 1: Write the failing test

Add coverage that freezes:

- assistant-bubble replay identity
- descendant task contribution to the parent bubble
- refresh behavior for interrupted/superseded/hidden nodes

### Task 2 / Step 2: Run test to verify it fails

Run the new replay/refresh scope tests.

Expected: FAIL because the current contract has not frozen this boundary.

### Task 2 / Step 3: Write minimal implementation

Implement the minimum query and replay rules needed so all later work builds on one stable scope model.

### Task 2 / Step 4: Run test to verify it passes

Run the scope tests again.

Expected: PASS

## Task 3: Emit structured task execution lifecycle events

### Task 3 Files

- Modify: `lib/dag/node_event_stream.rb`
- Modify: `lib/agent_core/dag/executors/task_executor.rb`
- Possibly modify: `lib/dag/runner.rb`
- Test: add coverage under `test/lib/dag/` and/or `test/scenarios/dag/`

### Task 3 / Step 1: Write the failing test

Add tests that assert durable task progress events exist for:

- task queued/bound
- task start
- task update/log
- task finish
- task error
- task authorization required where relevant

### Task 3 / Step 2: Run test to verify it fails

Run the new task lifecycle test(s).

Expected: FAIL because current task execution ignores `stream:` and does not emit a structured UI contract.

### Task 3 / Step 3: Write minimal implementation

Extend task execution so durable task lifecycle changes are emitted as structured node events with stable payload keys.

Do not reuse the old generic text-only `progress/log` contract as the primary representation.

The first pass should be safe to implement as **lifecycle milestones only** if a clean task-side progress/log API does not yet exist.

### Task 3 / Step 4: Run test to verify it passes

Run the new task lifecycle tests again.

Expected: PASS

## Task 4: Add a durable `run_state` projection for assistant messages

### Task 4 Files

- Modify: `lib/dag/transcript_projection.rb`
- Modify: `app/models/conversation.rb`
- Possibly create: `app/models/conversation/run_state_projector.rb`
- Test: add projection-focused coverage under `test/models/` or `test/lib/dag/`

### Task 4 / Step 1: Write the failing test

Add tests that assert an `agent_message` projection can include:

- top-level `run_state.status`
- `run_state.phase_message`
- `run_state.summary`
- `run_state.tools[]`

Use minimal synthetic task descendants to prove that `run_state` comes from durable data rather than from transient UI state.

### Task 4 / Step 2: Run test to verify it fails

Run the new projection test file.

Expected: FAIL because no `run_state` projection exists today.

### Task 4 / Step 3: Write minimal implementation

Introduce a projector that computes `run_state` from:

- parent `agent_message` state/metadata
- descendant `task` node states
- task previews / outputs
- task-scoped node events if needed

Do not let the frontend compute this itself.

### Task 4 / Step 4: Run test to verify it passes

Run the projection test again.

Expected: PASS

## Task 5: Expose projected `run_state` in app-facing message reads

### Task 5 Files

- Modify: `lib/dag/transcript_projection.rb`
- Modify: `app/models/conversation.rb`
- Possibly modify: message read helpers / serializers
- Test: add integration/projection coverage

### Task 5 / Step 1: Write the failing test

Add coverage that proves:

- `Conversation#message_for_node_id` returns `run_state`
- `Conversation#message_page` / transcript reads include `run_state` for running assistant bubbles
- terminal assistant messages collapse back to ordinary final content while preserving any desired summary fields

### Task 5 / Step 2: Run test to verify it fails

Run the new message projection test(s).

Expected: FAIL because current projection only exposes text preview/output and metadata.

### Task 5 / Step 3: Write minimal implementation

Project `run_state` into app-facing message hashes and ensure the projector consumes the durable binding/execution truth from Tasks 1–3.

### Task 5 / Step 4: Run test to verify it passes

Run the projection tests again.

Expected: PASS

## Task 6: Replace the realtime contract with structured tool lifecycle payloads

### Task 6 Files

- Modify: `app/channels/conversation_channel.rb`
- Modify: `app/javascript/controllers/conversation_channel_controller.js`
- Test: `test/channels/conversation_channel_test.rb`
- Test: integration coverage for replay and message refresh interaction

### Task 6 / Step 1: Write the failing test

Add channel/controller-facing coverage that asserts:

- structured `tool_*` event kinds exist
- payloads are machine-readable and node-scoped
- replay batches carry those payloads correctly
- no tool contract depends on `event.text`

### Task 6 / Step 2: Run test to verify it fails

Run the channel/controller-focused tests.

Expected: FAIL because the current contract only exposes `output_delta`, `output_compacted`, `progress`, and `log`.

### Task 6 / Step 3: Write minimal implementation

Change the conversation realtime contract so it can transmit structured tool lifecycle payloads. Preserve wrapper-level durable truth and do not rely on the client seeing every event.

### Task 6 / Step 4: Run test to verify it passes

Run the channel/controller tests again.

Expected: PASS

## Task 7: Reset the running assistant bubble UI

### Task 7 Files

- Modify: `app/views/conversation_messages/_message.html.erb`
- Possibly create shared partial(s) for the tool-progress region
- Modify: `app/javascript/controllers/conversation_channel_controller.js`
- Test: integration/UI coverage under `test/integration/`
- Test: E2E coverage under `test/e2e/`

### Task 7 / Step 1: Write the failing test

Add coverage that asserts:

- a running assistant bubble renders a structured tool progress block
- multiple tools can be shown at once
- tool states update live without requiring a full page reload
- terminal convergence removes or collapses the running-state block correctly

### Task 7 / Step 2: Run test to verify it fails

Run the new integration/E2E tests.

Expected: FAIL because the current bubble only has a single hidden progress line and plain text span.

### Task 7 / Step 3: Write minimal implementation

Replace the old single-line running state with:

- a run summary row
- a compact per-tool list
- optional expandable details if needed

Keep `message_<node_id>` as the durable wrapper-level UI unit.

### Task 7 / Step 4: Run test to verify it passes

Run the integration/E2E tests again.

Expected: PASS

## Task 8: Harden refresh, replay, and terminal convergence

### Task 8 Files

- Modify: `app/models/conversation.rb`
- Modify: `app/controllers/conversation_messages_controller.rb`
- Modify: `app/channels/conversation_channel.rb`
- Possibly modify: any retention/compaction helpers for tool-progress events
- Test: reconnect/resume and refresh coverage

### Task 8 / Step 1: Write the failing test

Add coverage for:

- reconnect after missed tool events
- `messages/refresh` reconstructing the same `run_state`
- terminal wrapper replace converging from running tool state to final assistant output
- retries preserving truthful tool-state transitions
- stale replay after interrupt/steer being ignored correctly once input-policies semantics are in place

### Task 8 / Step 2: Run test to verify it fails

Run the replay/refresh/reconnect tests.

Expected: FAIL until the new contract is wired into durable reads and replay.

### Task 8 / Step 3: Write minimal implementation

Ensure the durable message projection alone is sufficient to reconstruct tool progress, with cable events treated as acceleration rather than sole truth.

Define any required event retention/coalescing rules so high-frequency tool progress does not bloat replay indefinitely.

### Task 8 / Step 4: Run test to verify it passes

Run the replay/refresh/reconnect tests again.

Expected: PASS

## Task 9: Final verification

### Task 9 Files

- Verify: `lib/agent_core/dag/executors/agent_message_executor.rb`
- Verify: `lib/agent_core/dag/executors/task_executor.rb`
- Verify: `lib/dag/node_event_stream.rb`
- Verify: `lib/dag/transcript_projection.rb`
- Verify: `app/models/conversation.rb`
- Verify: `app/channels/conversation_channel.rb`
- Verify: `app/javascript/controllers/conversation_channel_controller.js`
- Verify: `app/views/conversation_messages/_message.html.erb`

### Task 9 / Step 1: Run focused verification

Run the exact set of updated tests covering:

- planning/binding durability
- task lifecycle events
- message projection
- channel replay
- running assistant bubble UI
- reconnect/refresh/terminal convergence

### Task 9 / Step 2: Check lint diagnostics

Run `ReadLints` on changed Ruby/JS/view files and fix newly introduced issues.

### Task 9 / Step 3: Re-read the design

Confirm the final implementation still matches the design goals:

- task execution is first-class durable truth
- assistant bubble remains the default UX surface
- `run_state` is projected server-side
- structured tool lifecycle events exist
- refresh/reconnect truth does not depend on seeing every cable event
- no regression to raw provider-wire coupling in the frontend
