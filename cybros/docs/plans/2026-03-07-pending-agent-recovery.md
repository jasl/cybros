# Pending Agent Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add manual start for the tail pending assistant and silently repair stale pending assistants when newer user input arrives.

**Architecture:** Extend the conversation action policy/UI to expose a narrow `Start` action for the tail pending assistant. Implement both manual start and silent pending-assistant repair inside the `Conversation` facade under the graph lock so concurrent `Start`/append requests converge safely. Keep abandoned pending assistants out of transcript/context by silently terminalizing and hiding them before building the new tail.

**Tech Stack:** Rails 8, ERB, Stimulus, Minitest, DAG scheduler/runner, Conversation facade

---

### Task 1: Lock action-policy and UI expectations

**Files:**
- Modify: `cybros/test/models/conversation_node_action_policy_test.rb`
- Modify: `cybros/test/integration/conversation_action_policy_ui_test.rb`

**Step 1: Write the failing test**

- Assert `Start` is available only for a tail `pending agent_message`.
- Assert the conversation page renders a message-level `Start` button for that state.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/conversation_node_action_policy_test.rb test/integration/conversation_action_policy_ui_test.rb`
Expected: FAIL because `Start` is not part of the action policy or bubble UI.

### Task 2: Lock silent repair behavior in the conversation facade

**Files:**
- Modify: `cybros/test/models/conversation_chat_facade_test.rb`

**Step 1: Write the failing test**

- Build a conversation whose chat tail is an unstarted pending assistant.
- Append a new user message.
- Assert the stale pending assistant is terminal, hidden from transcript/context, and its run is canceled.
- Assert the new user/assistant tail sequences from the stale node’s stable parent rather than from the stale node.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/conversation_chat_facade_test.rb`
Expected: FAIL because appending behind a stale pending assistant currently leaves the stale node in the chain.

### Task 3: Lock manual-start execution behavior

**Files:**
- Modify: `cybros/test/models/conversation_chat_facade_test.rb`
- Modify: `cybros/test/integration/conversation_messages_dual_channel_test.rb`

**Step 1: Write the failing test**

- Assert a manual start API/facade call claims the tail pending assistant and enqueues execution.
- Assert starting a non-tail or already-superseded pending assistant fails cleanly.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/conversation_chat_facade_test.rb test/integration/conversation_messages_dual_channel_test.rb`
Expected: FAIL because no manual-start action exists.

### Task 4: Implement policy, UI, and facade changes

**Files:**
- Modify: `cybros/app/models/conversation/node_action_policy.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/app/javascript/controllers/message_actions_controller.js`
- Modify: `cybros/app/views/conversation_messages/_message.html.erb`
- Modify: `cybros/config/routes.rb`

**Step 1: Write minimal implementation**

- Add `Start` action-policy support for tail pending assistants.
- Add a `start` endpoint/action.
- Add facade helpers to:
  - manually claim and enqueue the tail pending assistant
  - silently archive stale pending assistants before appending new user input
- Reuse the graph lock and run-tracker plumbing to keep races deterministic.

**Step 2: Run focused tests to verify they pass**

Run: `bin/rails test test/models/conversation_node_action_policy_test.rb test/integration/conversation_action_policy_ui_test.rb test/models/conversation_chat_facade_test.rb test/integration/conversation_messages_dual_channel_test.rb`
Expected: PASS

### Task 5: Final verification

**Files:**
- No new files

**Step 1: Run targeted regression checks**

Run: `bin/rails test test/integration/conversations_test.rb test/integration/conversation_messages_dual_channel_test.rb test/models/conversation_chat_facade_test.rb test/models/conversation_node_action_policy_test.rb test/integration/conversation_action_policy_ui_test.rb test/jobs/dag/tick_graph_job_test.rb`
Expected: PASS
