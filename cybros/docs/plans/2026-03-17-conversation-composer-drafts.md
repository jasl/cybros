# Conversation Composer Drafts Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist composer content, model selection, and permission mode without page-level refreshes, and apply runtime-setting changes starting with the next turn only.

**Architecture:** Add a conversation-scoped `composer_draft` JSONB column, expose a narrow autosave endpoint, render the composer from resolved draft state, and promote draft settings into conversation defaults only when a new message is submitted. Keep `RunDraft` as the execution snapshot and do not reuse it for unsent UI state.

**Tech Stack:** Rails 8, PostgreSQL JSONB, Stimulus, Turbo, Playwright E2E, Minitest

---

### Task 1: Add conversation composer draft storage

**Files:**
- Create: `cybros/db/migrate/20260317120000_add_composer_draft_to_conversations.rb`
- Modify: `cybros/db/schema.rb`
- Modify: `cybros/app/models/conversation.rb`
- Test: `cybros/test/models/conversation_test.rb`

**Step 1: Write the failing test**

Add a model test proving `Conversation` normalizes a `composer_draft` payload and exposes resolved draft values with fallbacks to saved conversation defaults.

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && pg_isready && bin/rails test test/models/conversation_test.rb`

Expected: FAIL because `composer_draft` storage / helpers do not exist yet.

**Step 3: Write minimal implementation**

- add `composer_draft jsonb default {} null: false`
- normalize `composer_draft`
- add helpers for resolved composer content, model ref, and permission mode

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && pg_isready && bin/rails test test/models/conversation_test.rb`

Expected: PASS

### Task 2: Add a narrow composer-draft update endpoint

**Files:**
- Modify: `cybros/config/routes.rb`
- Create: `cybros/app/controllers/conversation_composer_drafts_controller.rb`
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/app/services/conversations/runtime_settings_updater.rb`
- Test: `cybros/test/integration/conversation_composer_drafts_test.rb`

**Step 1: Write the failing test**

Add an integration test proving `PATCH /conversations/:id/composer_draft` updates only `composer_draft`, returns a narrow success response, and does not require a redirect to `show`.

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && pg_isready && bin/rails test test/integration/conversation_composer_drafts_test.rb`

Expected: FAIL because the route/controller does not exist yet.

**Step 3: Write minimal implementation**

- add member route
- implement ownership-scoped controller update
- validate/sanitize incoming `content`, `model_ref`, and `permission_mode`
- return `204` or compact JSON only

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && pg_isready && bin/rails test test/integration/conversation_composer_drafts_test.rb`

Expected: PASS

### Task 3: Publish composer draft settings on send

**Files:**
- Modify: `cybros/app/controllers/conversation_messages_controller.rb`
- Modify: `cybros/app/models/conversation.rb`
- Test: `cybros/test/integration/conversation_messages_controller_test.rb`
- Test: `cybros/test/integration/conversation_permission_mode_test.rb`

**Step 1: Write the failing test**

Add integration coverage proving:

- unsent draft `permission_mode` and `model_ref` are applied when the next message is sent
- the current running turn is unaffected by later composer draft edits
- successful send clears only draft content and keeps chosen settings as defaults

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && pg_isready && bin/rails test test/integration/conversation_messages_controller_test.rb test/integration/conversation_permission_mode_test.rb`

Expected: FAIL because send still reads directly from current conversation defaults / form-only settings.

**Step 3: Write minimal implementation**

- resolve effective composer draft on create
- promote `model_ref` / `permission_mode` into conversation defaults inside the send path
- clear draft content after successful create

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && pg_isready && bin/rails test test/integration/conversation_messages_controller_test.rb test/integration/conversation_permission_mode_test.rb`

Expected: PASS

### Task 4: Move the composer UI to autosave instead of page-level settings submit

**Files:**
- Modify: `cybros/app/views/conversations/show.html.erb`
- Modify: `cybros/app/javascript/controllers/message_form_controller.js`
- Create or Modify: `cybros/app/javascript/lib/conversation_composer_state.js`
- Test: `cybros/test/js/message_form_controller.test.js`

**Step 1: Write the failing test**

Add a JS test proving textarea edits and runtime-setting changes schedule composer-draft autosaves and do not call the old hidden permission form submit path.

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bun test test/js/message_form_controller.test.js`

Expected: FAIL because autosave wiring does not exist yet.

**Step 3: Write minimal implementation**

- remove the hidden permission form usage from the composer surface
- initialize textarea/model/permission controls from resolved draft state
- debounce autosave requests for content/model/permission changes
- keep in-flight send behavior intact

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bun test test/js/message_form_controller.test.js`

Expected: PASS

### Task 5: Lock the user-facing behavior with E2E regressions

**Files:**
- Modify: `cybros/test/e2e/responsive_shell.spec.ts`
- Modify: `cybros/test/e2e/connectivity_health.spec.ts`
- Modify: `cybros/test/e2e/conversation_mock_llm_streaming.spec.ts`
- Create or Modify: `cybros/test/e2e/conversation_runtime_settings_draft.spec.ts`

**Step 1: Write the failing test**

Add E2E coverage proving:

- permission/model changes do not trigger page-level regressions
- unsent text survives runtime-setting changes
- markdown rendering remains intact
- the chosen settings apply on the next send and remain selected afterward

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/ci_e2e test/e2e/conversation_mock_llm_streaming.spec.ts test/e2e/responsive_shell.spec.ts test/e2e/connectivity_health.spec.ts`

Expected: FAIL until autosave draft behavior replaces the redirect path.

**Step 3: Write minimal implementation**

Update only the code needed to satisfy the new E2E expectations.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/ci_e2e test/e2e/conversation_mock_llm_streaming.spec.ts test/e2e/responsive_shell.spec.ts test/e2e/connectivity_health.spec.ts`

Expected: PASS

### Task 6: Run focused verification and close the old path

**Files:**
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/app/services/conversations/runtime_settings_updater.rb`
- Test: any tests broken by removal of the old hidden permission submit path

**Step 1: Verify old path usage**

Search for composer-surface callers that still depend on `ConversationsController#update` redirect behavior.

Run: `cd /Users/jasl/Workspaces/Cybros/cybros && rg -n "permission_mode_form|requestSubmit\\(|conversation\\[permission_mode\\]" cybros/app cybros/test`

Expected: only intentional non-composer usage remains.

**Step 2: Remove composer-only leftovers**

- delete hidden permission form from the composer
- ensure runtime settings updater is no longer part of composer autosave

**Step 3: Run focused verification**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros
pg_isready
bin/rails test test/models/conversation_test.rb \
  test/integration/conversation_composer_drafts_test.rb \
  test/integration/conversation_messages_controller_test.rb \
  test/integration/conversation_permission_mode_test.rb
bin/ci_e2e test/e2e/conversation_mock_llm_streaming.spec.ts \
  test/e2e/responsive_shell.spec.ts \
  test/e2e/connectivity_health.spec.ts
```

Expected: all green

**Step 4: Final verification before completion**

Run any additional directly affected JS/unit tests and confirm the composer no longer causes page-level morph side effects.
