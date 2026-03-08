# Queued Composer Alert Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the conversation composer card with a compact queued-input alert that only appears when queued turns exist and supports expand/collapse plus per-item edit, steer, and cancel actions.

**Architecture:** Keep the form submission policy logic in the existing conversation composer flow, but replace the current rail partial with a compact alert partial driven by richer queued-turn data from `Conversation::ComposerState`. Add façade-level queued-turn rewrite operations so edit/cancel/steer can safely rebuild the queued turn list without leaving invalid DAG edges or stale runs behind.

**Tech Stack:** Rails 8, Stimulus, Turbo Streams, Minitest, Bun JS tests

---

### Task 1: Lock the new queue alert behavior with failing tests

**Files:**
- Modify: `cybros/test/integration/conversations_test.rb`
- Modify: `cybros/test/models/conversation_chat_facade_test.rb`
- Modify: `cybros/test/js/conversation_composer_state.test.js`
- Create: `cybros/test/integration/conversation_queue_items_test.rb`

**Step 1: Write the failing test**

- Assert the conversation page no longer renders the Composer card labels and instead renders a compact queued alert only when queued turns exist.
- Assert the queued alert renders at most four queued items, keeps the earliest queued message as the collapsed summary, and exposes per-item action affordances.
- Assert queue edit/cancel rebuild the queue without dropping unrelated queued turns.
- Assert queue steer reuses the selected queued content for the current turn while preserving the remaining queued turns.
- Assert the draft prepend helper puts edited content ahead of existing textarea content with a newline separator.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/conversations_test.rb test/integration/conversation_queue_items_test.rb test/models/conversation_chat_facade_test.rb && bun test test/js/conversation_composer_state.test.js`

Expected: FAIL because the current card UI, missing queue-item endpoints, and missing rewrite helpers do not match the new behavior.

**Step 3: Write minimal implementation**

- Add queued-turn rewrite methods to `Conversation`.
- Add a compact queued alert partial and supporting controller/Stimulus changes.
- Add queue-item controller endpoints that return JSON with Turbo Stream replacements.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/conversations_test.rb test/integration/conversation_queue_items_test.rb test/models/conversation_chat_facade_test.rb && bun test test/js/conversation_composer_state.test.js`

Expected: PASS

**Step 5: Commit**

```bash
git add docs/plans/2026-03-07-queued-composer-alert.md cybros/app cybros/config/routes.rb cybros/test
git commit -m "feat: replace composer rail with queued alert"
```

### Task 2: Implement queued-turn rewrite support in the conversation façade

**Files:**
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/conversation/composer_state.rb`
- Test: `cybros/test/models/conversation_chat_facade_test.rb`

**Step 1: Write the failing test**

- Build a running conversation with several queued turns.
- Remove one queued turn and assert the surviving queued turns remain in order and keep valid queue dependencies.
- Steer one queued turn and assert the selected content is applied to the current turn while the other queued turns are rebuilt behind it.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/conversation_chat_facade_test.rb`

Expected: FAIL with missing methods or invalid graph behavior.

**Step 3: Write minimal implementation**

- Snapshot queued turns as ordered `{ user_node_id, content, model_ref }` records.
- Archive the queued turn bundles and cancel their runs under the graph lock.
- Rebuild the remaining queued turns in order, disabling coalescing during reconstruction.
- Reuse `steer_current_turn!` for the selected queued content after clearing queued descendants.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/conversation_chat_facade_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/app/models/conversation.rb cybros/app/models/conversation/composer_state.rb cybros/test/models/conversation_chat_facade_test.rb
git commit -m "feat: add queued turn rewrite operations"
```

### Task 3: Replace the composer card with the compact queued alert UI

**Files:**
- Modify: `cybros/app/views/conversations/_composer_status_rail.html.erb`
- Modify: `cybros/app/views/conversations/show.html.erb`
- Modify: `cybros/app/javascript/controllers/message_form_controller.js`
- Modify: `cybros/app/javascript/lib/conversation_composer_state.js`
- Test: `cybros/test/integration/conversations_test.rb`
- Test: `cybros/test/js/conversation_composer_state.test.js`

**Step 1: Write the failing test**

- Assert the old Composer labels/buttons are gone.
- Assert the alert summary is single-line by default, has an expand/collapse affordance, and shows up to four queued items when expanded.
- Assert the JS helper prepends edited content into the draft correctly.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/conversations_test.rb && bun test test/js/conversation_composer_state.test.js`

Expected: FAIL because the old card partial is still rendered.

**Step 3: Write minimal implementation**

- Render only queue data in the partial; keep hidden state attributes needed by the form controller.
- Add per-item icon buttons with accessible labels and disabled steer state when steering is unavailable.
- Add Stimulus handlers for expand/collapse, edit, steer, cancel, Turbo Stream JSON handling, and draft prepend behavior.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/conversations_test.rb && bun test test/js/conversation_composer_state.test.js`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/app/views/conversations/_composer_status_rail.html.erb cybros/app/views/conversations/show.html.erb cybros/app/javascript/controllers/message_form_controller.js cybros/app/javascript/lib/conversation_composer_state.js cybros/test/integration/conversations_test.rb cybros/test/js/conversation_composer_state.test.js
git commit -m "feat: add compact queued composer alert"
```

### Task 4: Add queue-item web endpoints and response refreshes

**Files:**
- Create: `cybros/app/controllers/conversation_queue_items_controller.rb`
- Modify: `cybros/config/routes.rb`
- Test: `cybros/test/integration/conversation_queue_items_test.rb`

**Step 1: Write the failing test**

- POST edit returns Turbo Stream replacements and removes the selected queued turn from the conversation.
- POST steer returns Turbo Stream replacements and keeps the remaining queued turns.
- DELETE cancel returns Turbo Stream replacements and removes only the selected queued turn.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/conversation_queue_items_test.rb`

Expected: FAIL with missing routes or controller actions.

**Step 3: Write minimal implementation**

- Add nested queued-item routes under conversations.
- Return JSON `{ ok: true, turbo_stream: ... }` responses so Stimulus can patch the page without a full reload.
- Reuse the same message-list and composer-status partial refreshes as the normal message create flow.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/conversation_queue_items_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/app/controllers/conversation_queue_items_controller.rb cybros/config/routes.rb cybros/test/integration/conversation_queue_items_test.rb
git commit -m "feat: add queued composer item endpoints"
```

### Task 5: Verify the finished behavior

**Files:**
- No new files

**Step 1: Run the focused verification suite**

Run:

```bash
bin/rails test test/integration/conversations_test.rb test/integration/conversation_queue_items_test.rb test/models/conversation_chat_facade_test.rb
bun test test/js/conversation_composer_state.test.js
```

Expected: PASS

**Step 2: Optional broader regression check**

Run:

```bash
bin/rails test test/integration/steer_current_turn_test.rb test/scenarios/dag/user_input_while_running_flow_test.rb
```

Expected: PASS

**Step 3: Review**

- Confirm the composer alert is absent when there is no queue.
- Confirm edit restores content to the textarea ahead of any existing draft text.
- Confirm cancel and steer remove the selected queued message from the alert and the message list refreshes.

**Step 4: Commit**

```bash
git add docs/plans/2026-03-07-queued-composer-alert.md
git commit -m "docs: record queued composer alert plan"
```
