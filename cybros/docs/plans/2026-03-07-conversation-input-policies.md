# Conversation Input Policies Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement conversation input policies covering unlimited manual retry, all-entrypoint user-message coalescing, formal `queue` / `interrupt_new_turn` / `steer_current_turn` handling, action-level interrupted-output overrides, and oversize input guards.

**Architecture:** Keep policy selection in the App layer and keep the DAG focused on expressing the resolved result. Use `agent_profile` defaults plus conversation metadata overrides, then let App/channel/user choice resolve the final policy. Allow `retry` and `steer_current_turn` to pass action-level `interrupted_output_policy_override` values that outrank static defaults. For oversize handling, distinguish single-message hard overflow from accumulated context overflow, and model guard/compaction as explicit DAG-visible behavior rather than hidden request-time magic. Treat `steer_current_turn` as same-turn user-input version replacement with capability gating and policy-driven fallback, while leaving real workspace cleanup/revert deferred as TODO.

**Tech Stack:** Ruby 4.0, Rails 8 alpha, ActiveSupport tests, `Conversation` facade, DAG engine (`DAG::Node`, `DAG::Graph`, `DAG::Mutations`, `DAG::Scheduler`, `DAG::Runner`), AgentCore prompt/context budgeting.

**Coordination Note:** Future tool-progress work should treat queue / steer / candidate-next-input rail state as composer/conversation state, not as assistant-bubble `run_state`. Preflight policy tasks such as `compress_input` / `compact_context` should remain separate from assistant-owned execution state unless a later turn-level execution contract is explicitly introduced.

## Execution order and dependency constraints

Recommended order:

1. Task 1 (`manual retry`)
2. Task 2 (`policy resolver`)
3. Task 3 (`coalescing + claim_after_at`)
4. Task 4 (`queue` and `interrupt_new_turn`)
5. Task 5 (`interrupted-output policies + action-level override plumbing`)
6. Task 6 (`single-message oversize guard + product_message`)
7. Task 7 (`transient compact_context`)
8. Task 8 (`steer_current_turn`)
9. Task 9 (`conversation composer UI`)
10. Task 10 (`final verification`)

Hard dependencies:

- Task 2 must land before Tasks 4, 5, 6, 7, and 8.
- Task 3 must land before Task 6 and Task 7, because oversize classification happens after coalescing.
- Task 4 must land before Task 8, because steer fallback is `interrupt_new_turn`.
- Task 5 must land before Task 8, because steer shares the interrupted-output policy machinery and action-level override shape.
- Task 6 should land before Task 7, because single-message overflow behavior is simpler and defines the app-layer guard surface first.
- Task 8 should land before Task 9, because the composer rail needs to reflect real steer capability/state rather than a placeholder.

---

## Task 1: Remove the manual retry count limit while preserving audit depth

### Task 1 Files

- Modify: `app/models/conversation/node_action_policy.rb`
- Modify: `app/models/conversation.rb`
- Test: `test/integration/retry_generation_test.rb`
- Test: add/extend policy-level test under `test/models/` or `test/integration/`

### Task 1 / Step 1: Write the failing test

Add a regression test that creates an assistant retry chain deeper than 5 attempts and asserts:

- manual retry remains available
- `Conversation#retry_agent_node!` does not raise `retry_limit_reached`
- `retry_already_queued` and graph-topology safety checks still apply

### Task 1 / Step 2: Run test to verify it fails

Run: `bin/rails test test/integration/retry_generation_test.rb`

Expected: FAIL because retry depth currently disables manual retry.

### Task 1 / Step 3: Write minimal implementation

Remove the retry-depth availability gate from:

- `Conversation::NodeActionPolicy#retry_entry`
- any manual retry path in `Conversation#retry_agent_node!` that still treats `retry_limit_reached` as a user-facing error

Keep retry depth calculation available for metadata/stats only.

### Task 1 / Step 4: Run test to verify it passes

Run: `bin/rails test test/integration/retry_generation_test.rb`

Expected: PASS

## Task 2: Add policy config resolution for input behavior

### Task 2 Files

- Modify: `cybros-agent/profiles/default-assistant/agent.yml`
- Modify: `app/models/conversation.rb`
- Modify: `lib/cybros/agent_profiles.rb` or related config/resolution code
- Test: add/extend `test/lib/cybros/agent_profile_config_test.rb`

### Task 2 / Step 1: Write the failing test

Add tests that prove final policy resolution order:

- conversation metadata overrides `agent_profile`
- app-level explicit override can be layered on top later
- action-level `interrupted_output_policy_override` outranks static defaults for `retry` and `steer_current_turn`
- defaults exist for:
  - `input_coalescing.enabled`
  - `input_coalescing.window_ms`
  - `running_input_policy`
  - `interrupted_output_policy`
  - `steer_capability`
  - `steer_cleanup_policy`
  - `steer_after_side_effects`
  - single-message soft oversize threshold/strategy
  - single-message hard oversize threshold/strategy
  - multi-message/context overflow strategy

### Task 2 / Step 2: Run test to verify it fails

Run: `bin/rails test test/lib/cybros/agent_profile_config_test.rb`

Expected: FAIL because those policy keys/resolution rules do not exist yet.

### Task 2 / Step 3: Write minimal implementation

Introduce stable resolution helpers that produce effective input policy config from:

- global defaults
- `agent_profile`
- conversation metadata

Do not implement persisted user/app explicit override storage yet; runtime app/channel override hooks may still be passed through service/controller arguments.

### Task 2 / Step 4: Run test to verify it passes

Run: `bin/rails test test/lib/cybros/agent_profile_config_test.rb`

Expected: PASS

## Task 3: Implement all-entrypoint message coalescing before agent execution begins

### Task 3 Files

- Modify: `app/models/conversation.rb`
- Modify: `lib/dag/scheduler.rb` or claimability logic if needed
- Modify: `app/models/dag/node.rb` to expose the claim-delay field if needed
- Modify: `db/schema.rb`
- Add/Modify migration for a persisted `dag_nodes.claim_after_at`
- Modify: any queue-policy helpers currently assuming one user message per immediate turn
- Test: add scenario coverage under `test/scenarios/dag/`

### Task 3 / Step 1: Write the failing test

Add a scenario test that:

- appends a user message
- before the downstream assistant starts executing, appends more user fragments
- asserts only one logical user turn is created
- asserts merged content is used for the turn
- asserts `metadata["fragments"]` preserves the originals
- asserts a queued burst of follow-up fragments still collapses into one queued logical turn before the queued assistant becomes claimable

### Task 3 / Step 2: Run test to verify it fails

Run the new scenario test.

Expected: FAIL because current behavior creates a new turn immediately.

### Task 3 / Step 3: Write minimal implementation

Change the conversation append flow so that:

- the downstream assistant can exist in a non-claimable pending state during the coalescing window
- the non-claimable state is modeled by a persisted `claim_after_at` field on the executable node, not by an out-of-band transient buffer
- `DAG::Scheduler` filters pending executable nodes by `claim_after_at`
- subsequent short user inputs merge into the same logical user message before assistant execution begins
- merged text becomes the final `user_message.content`
- original fragments are written to `user_message.metadata["fragments"]`

### Task 3 / Step 4: Run test to verify it passes

Run the scenario test again.

Expected: PASS

## Task 4: Implement running-turn input strategies (`queue` and `interrupt_new_turn`)

### Task 4 Files

- Modify: `app/models/conversation.rb`
- Modify: DAG mutation flow if needed for clean new-turn creation
- Reuse / extend: `test/scenarios/dag/user_input_while_running_flow_test.rb`

### Task 4 / Step 1: Write the failing test

Extend existing scenario coverage so product-level policy can choose:

- `queue`
- `interrupt_new_turn`

and verify both paths produce the expected transcript and context behavior.

### Task 4 / Step 2: Run test to verify it fails

Run: `bin/rails test test/scenarios/dag/user_input_while_running_flow_test.rb`

Expected: FAIL until policy-driven selection is wired through the app layer.

### Task 4 / Step 3: Write minimal implementation

Make app-layer input handling explicitly resolve the effective running-input policy:

- `queue` keeps the current agent turn running and schedules the next user turn afterward
- `interrupt_new_turn` stops the current turn and starts a new user/assistant turn
- `queue` is treated as a formal first-class product strategy, not only as an implicit dependency-edge side effect
- for `interrupt_new_turn`, attach the new `user_message` from the interrupted assistant turn's last stable sequence parent rather than the interrupted assistant itself
- before the new turn becomes claimable, cancel/stop or otherwise neutralize any pending/running descendants in the interrupted causal closure

Leave `steer_current_turn` to its dedicated task below.

### Task 4 / Step 4: Run test to verify it passes

Run: `bin/rails test test/scenarios/dag/user_input_while_running_flow_test.rb`

Expected: PASS

## Task 5: Implement interrupted-output policies (`discard_context` and `keep_context`)

### Task 5 Files

- Modify: `app/models/conversation.rb`
- Modify: `app/controllers/conversations_controller.rb`
- Modify: any projection/action helpers that need policy metadata
- Modify: any action callers that need to pass overrides (for example Stimulus / API callers)
- Reuse / extend: `test/scenarios/dag/user_input_while_running_flow_test.rb`

### Task 5 / Step 1: Write the failing test

Add/extend scenario coverage so interrupted output can be:

- kept visible but excluded from future context
- kept visible and retained in future context
- overridden per action via `interrupted_output_policy_override` on retry and steer paths

### Task 5 / Step 2: Run test to verify it fails

Run the relevant scenario test(s).

Expected: FAIL until the product policy is applied consistently.

### Task 5 / Step 3: Write minimal implementation

Use existing engine primitives:

- `stop!`
- `exclude_from_context!` / `request_exclude_from_context!`

Do not add new DAG primitives if existing visibility semantics are sufficient.

Plumb action-level override parameters through app-facing retry and future steer entrypoints so one action can intentionally differ from the static conversation default.

### Task 5 / Step 4: Run test to verify it passes

Run the scenario test(s) again.

Expected: PASS

## Task 6: Add single-message oversize guard behavior

### Task 6 Files

- Modify: `app/models/conversation.rb`
- Possibly create: `app/models/conversation/input_guard.rb` or similar app-layer helper
- Create: `app/models/messages/product_message.rb`
- Modify: message projection / transcript rendering for `product_message`
- Modify: message projection/rendering if synthetic guard responses need explicit metadata
- Test: add integration/scenario coverage

### Task 6 / Step 1: Write the failing test

Add coverage for:

- soft single-message oversize -> explicit `task(compress_input)` before the main assistant turn
- hard single-message oversize -> persist raw `user_message` then emit a visible `product_message`
- hard-oversize `product_message` does not expose assistant actions

### Task 6 / Step 2: Run test to verify it fails

Run the new test file.

Expected: FAIL because current append flow has no oversize guard split.

### Task 6 / Step 3: Write minimal implementation

Add a preflight input guard that runs after coalescing and before normal assistant execution:

- classify input size
- preserve the raw user message
- represent soft oversize through an explicit `task(compress_input)` output that feeds the main assistant turn
- emit a visible non-executable `product_message` for hard oversize
- keep later “compress for me” / “split” follow-up actions possible

### Task 6 / Step 4: Run test to verify it passes

Run the new tests again.

Expected: PASS

## Task 7: Add transient multi-message/context overflow compaction path

### Task 7 Files

- Modify: app-layer input/context guard helpers
- Possibly create: `task(compact_context)` generation path in the DAG mutation flow
- Test: add scenario coverage
- Reference: `lib/agent_core/dag/context_budget_manager.rb`

### Task 7 / Step 1: Write the failing test

Add coverage for accumulated-history overflow that asserts:

- the system chooses a transient compaction path
- it does not immediately materialize a durable `summary` node
- the main assistant turn runs against compacted context afterward

### Task 7 / Step 2: Run test to verify it fails

Run the new scenario/integration test.

Expected: FAIL until the transient compaction path exists.

### Task 7 / Step 3: Write minimal implementation

Implement a first-pass transient compaction path as a preflight task or helper result:

- keep original history intact
- do not persist durable `summary` nodes yet
- leave room for a later utility-agent decision path in ambiguous cases
- treat `compact_context` as an app-layer pre-turn response that coexists with, rather than replaces, engine-layer `AgentCore` `auto_compact`

### Task 7 / Step 4: Run test to verify it passes

Run the new tests again.

Expected: PASS

## Task 8: Implement first-pass `steer_current_turn`

### Task 8 Files

- Modify: `app/models/conversation.rb`
- Modify: any app-layer policy resolver for running-input strategy / steer capability
- Modify: DAG version-replacement helpers only if current user-input replacement primitives are insufficient
- Test: add scenario coverage under `test/scenarios/dag/`
- Test: add/extend transcript/page projection coverage for superseded steer versions
- Test: extend any app/policy tests needed for steer capability gating and fallback

### Task 8 / Step 1: Write the failing test

Add coverage that asserts:

- steer is capability-gated by profile/conversation policy
- steer creates a new user-input version in the same logical turn
- the superseded user-input version plus interrupted assistant partial are treated as one superseded block
- old user-input version leaves the normal transcript but remains auditable
- steer falls back to `interrupt_new_turn` when unavailable
- steer after side effects is policy-gated
- steer may pass an `interrupted_output_policy_override`
- actual workspace cleanup/revert remains TODO and is not performed in this pass
- transcript/page projection hides superseded user versions in normal transcript while audit/version history retains them

### Task 8 / Step 2: Run test to verify it fails

Run the new steer-focused scenario/integration test(s).

Expected: FAIL because steer does not exist yet.

### Task 8 / Step 3: Write minimal implementation

Implement first-pass steer semantics:

- same logical turn
- new user-input version
- superseded user-input + interrupted assistant partial handled as one superseded block
- old user-input version hidden from normal transcript
- capability gating via `agent_profile` and conversation metadata
- fallback to `interrupt_new_turn` when steer is unavailable
- support action-level `interrupted_output_policy_override`

Do not implement real workspace cleanup/revert in this task. Record/propagate the chosen cleanup policy only.

### Task 8 / Step 4: Run test to verify it passes

Run the steer-focused test(s) again.

Expected: PASS

## Task 9: Implement conversation composer UI for queue / steer / candidate preview

### Task 9 Files

- Modify: `app/views/conversations/show.html.erb`
- Possibly create: `app/views/conversations/_composer_status_rail.html.erb`
- Modify: relevant Stimulus controllers such as `app/javascript/controllers/conversation_channel_controller.js`, `app/javascript/controllers/chat_hotkeys_controller.js`, and `app/javascript/controllers/message_form_controller.js`
- Reference: `references/tavern_kit/playground/app/views/conversations/show.html.erb`
- Reference: `references/tavern_kit/playground/app/views/messages/_form.html.erb`
- Test: update/add integration and E2E coverage for composer state

### Task 9 / Step 1: Write the failing test

Add UI coverage that asserts:

- queue state appears above the composer input
- the composer can show a candidate next-input preview
- steer availability/mode is surfaced near the composer, not hidden only in backend state
- hard oversize guard stays transcript-visible as a `product_message`, not a composer-only warning

### Task 9 / Step 2: Run test to verify it fails

Run the relevant integration/E2E/UI test(s).

Expected: FAIL because the current conversation page does not surface these states.

### Task 9 / Step 3: Write minimal implementation

Implement a unified composer-adjacent status surface:

- a composer status rail above the text input
- queue indicator placed above the input field
- candidate next-input preview (lightweight, compact)
- steer hint/state indicator when relevant

Prefer extracting a reusable partial/component rather than scattering more alert-only state into `show.html.erb`.

Do not couple this composer rail to future assistant-bubble execution progress. It should remain a separate conversation/composer state surface.

### Task 9 / Step 4: Run test to verify it passes

Run the relevant integration/E2E/UI test(s) again.

Expected: PASS

## Task 10: Final verification

### Task 10 Files

- Verify: `app/models/conversation.rb`
- Verify: `app/models/conversation/node_action_policy.rb`
- Verify: any new helper files added for input guard/coalescing
- Verify: `test/integration/retry_generation_test.rb`
- Verify: `test/scenarios/dag/user_input_while_running_flow_test.rb`
- Verify: any new oversize/coalescing tests

### Task 10 / Step 1: Run focused verification

Run the exact set of updated tests covering:

- retry policy
- coalescing
- running-turn input handling
- formal `queue` semantics
- steer capability/fallback/versioning
- retry/steer action-level interrupted-output overrides
- composer UI surface for queue / steer / candidate preview
- interrupted-output context behavior
- oversize guard flows

### Task 10 / Step 2: Check lint diagnostics

Run `ReadLints` on changed Ruby files and fix newly introduced issues.

### Task 10 / Step 3: Re-read the design

Confirm the implementation still matches:

- unlimited manual retry
- all-entrypoint coalescing
- `queue`, `interrupt_new_turn`, and first-pass `steer_current_turn`
- queue/steer/candidate preview state visible in the web composer
- action-level interrupted-output overrides on `retry` and `steer_current_turn`
- synthetic guard responses for hard single-message oversize
- transient, not durable, compaction for multi-message/context overflow
- workspace cleanup/revert still deferred as TODO
