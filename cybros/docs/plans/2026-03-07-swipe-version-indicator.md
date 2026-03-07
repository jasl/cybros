# Swipe Version Indicator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show `x / y` inside the swipe control and disable unavailable swipe directions.

**Architecture:** Put version position and directional availability into the server-side swipe action policy, then render the control directly from that policy in the message partial. Keep keyboard hotkeys aligned with the same policy fields.

**Tech Stack:** Rails, Hotwire, Stimulus, TailwindCSS, DaisyUI, Minitest

---

### Task 1: Add failing swipe policy tests

**Files:**
- Modify: `test/models/conversation_node_action_policy_test.rb`

1. Add a failing test for a single finished assistant version asserting `current=1`, `total=1`, and both directions unavailable.
2. Add a failing test for a two-version tail asserting `current=2`, `total=2`, left available, right unavailable.
3. Run: `bin/rails test test/models/conversation_node_action_policy_test.rb`

### Task 2: Add failing UI tests

**Files:**
- Modify: `test/integration/conversation_action_policy_ui_test.rb`

1. Add a failing test asserting the rendered transcript includes `1 / 1` plus both disabled arrows.
2. Add a failing test asserting the active second version renders `2 / 2`, left enabled, right disabled.
3. Run: `bin/rails test test/integration/conversation_action_policy_ui_test.rb`

### Task 3: Implement swipe metadata and UI

**Files:**
- Modify: `app/models/conversation/node_action_policy.rb`
- Modify: `app/views/conversation_messages/_message.html.erb`
- Modify: `app/javascript/controllers/message_actions_controller.js`
- Modify: `app/javascript/controllers/chat_hotkeys_controller.js`

1. Extend the swipe action policy with `current`, `total`, `left_available`, and `right_available`.
2. Render the swipe join control with a center counter and directional disabled states.
3. Prevent directional swipe requests and keyboard hotkeys when the chosen direction is unavailable.

### Task 4: Verify and lint

**Files:**
- Verify: `test/models/conversation_node_action_policy_test.rb`
- Verify: `test/integration/conversation_action_policy_ui_test.rb`

1. Run: `bin/rails test test/models/conversation_node_action_policy_test.rb test/integration/conversation_action_policy_ui_test.rb test/models/conversation_chat_facade_test.rb test/integration/conversation_regenerate_swipe_test.rb`
2. Run: `bundle exec rubocop app/models/conversation/node_action_policy.rb app/views/conversation_messages/_message.html.erb app/controllers/conversations_controller.rb test/models/conversation_node_action_policy_test.rb test/integration/conversation_action_policy_ui_test.rb`
