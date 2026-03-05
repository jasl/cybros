# Phase 0.5 Completion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Complete Phase 0.5 (“UI + Streaming Hardening”) to the documented Acceptance Criteria, with the required edge/extreme test matrix passing.

**Architecture:** Drive work from Acceptance Criteria + Edge/extreme test matrix. Keep the App layer Conversation-first (no `DAG::*` in controllers/channels/views). Use “durable HTTP truth” (Turbo Streams) as the convergence layer and ActionCable as ephemeral delivery.

**Tech Stack:** Rails (Hotwire: Turbo Streams + ActionCable), Stimulus, Tailwind CSS 4 + daisyUI 5, Bun, Playwright (optional/on-demand).

---

### Task 1: Create the Phase 0.5 gap table (single source of truth)

**Files:**
- Create: `docs/plans/2026-03-05-phase-0-5-gap-table.md`
- Reference: `docs/product/roadmap.md` (Phase 0.5: Acceptance Criteria + Edge/extreme test matrix)

**Step 1: Write the gap table skeleton**

- Create sections:
  - Layouts & shell
  - Pages
  - Transport & ordering invariants
  - Chat UX state machine
  - Observability & debuggability
  - Auth/pagination/throttle/broadcast hardening
  - Edge/extreme test matrix (required)
- Use columns: Item / Status / Evidence / Gap / Next step / Test coverage.

**Step 2: Populate “Evidence” for already-implemented items**

- Examples of expected evidence anchors:
  - `config/routes.rb`
  - `app/controllers/conversation_messages_controller.rb`
  - `app/channels/conversation_channel.rb`
  - `app/javascript/controllers/conversation_channel_controller.js`
  - `app/javascript/lib/turbo_stream_buffer.js`
  - `app/models/event.rb`
  - Layouts: `app/views/layouts/{landing,agent,settings}.html.erb`

**Step 3: Mark Status (✅/🟡/❌) with explicit gaps**

- Every 🟡/❌ must have:
  - a concrete missing invariant or missing UI element, and
  - the smallest “Next step” action.

**Step 4: Derive the ordered worklist**

- Sort by risk/user impact:
  - transport correctness + convergence first
  - then failure UX
  - then hardening
  - then layout/pages completeness
  - then follow-up/polish

---

### Task 2: Make Playwright truly optional (`bin/e2e`) and runnable locally

**Files:**
- Create: `bin/e2e`
- Modify (if needed): `playwright.config.ts`, `package.json`, `bin/dev`, `bin/ci`
- Existing: `test/e2e/conversation_dual_channel.spec.ts`

**Step 1: Add `bin/e2e` runner script**

- Script responsibilities:
  - require a running dev server (or start one if we decide to)
  - run `bunx playwright test`
  - allow `E2E_BASE_URL` override

**Step 2: Verify it’s not part of CI by default**

- Ensure `bin/ci` does not call Playwright by default.

---

### Task 3: Ordering invariants — rapid sends (required)

**Files:**
- Modify: `test/e2e/conversation_dual_channel.spec.ts`
- (If needed) Modify: `app/controllers/conversation_messages_controller.rb`, `app/models/conversation.rb`

**Step 1: Write failing E2E test for rapid sends ordering**

- Extend Playwright test:
  - send 3–10 messages quickly (no awaits between fills/clicks other than UI-ready)
  - assert user bubbles appear in the exact order sent
  - assert each user message has a paired agent bubble (placeholder is sufficient)

**Step 2: Run the E2E test and confirm failure (if any)**

- Run:
  - `bunx playwright test test/e2e/conversation_dual_channel.spec.ts`

**Step 3: Fix pairing/order bugs (minimal changes)**

- Expected fix areas:
  - server: ensure `Conversation#append_user_message!` always links via lane head consistently
  - client: ensure Turbo Stream appends do not reorder; rely on DOM append only

---

### Task 4: Reconnect/resume without duplication (required)

**Files:**
- Modify: `test/channels/conversation_channel_test.rb`
- Modify: `app/channels/conversation_channel.rb` (only if gaps are found)
- Modify: `app/javascript/controllers/conversation_channel_controller.js` (only if gaps are found)

**Step 1: Add/adjust channel tests for cursor semantics**

- Ensure tests cover:
  - `replay_batch` resumes strictly after `cursor`
  - “preview exists → initialize cursor to latest event id → no replay”
  - `output_compacted` with blank text uses durable preview

**Step 2: Ensure App-facing tests don’t depend on `DAG::*` constants**

- Replace constants in `test/channels/**` with string kinds (`"output_delta"`, etc.) and `Conversation` facade helpers where appropriate.

---

### Task 5: Durable truth convergence (`messages/refresh`) end-to-end (required)

**Files:**
- Verify/Modify: `app/controllers/conversation_messages_controller.rb`
- Verify/Modify: `app/javascript/controllers/conversation_channel_controller.js`
- Verify/Modify: `app/models/event.rb`
- Verify/Modify: `app/views/conversation_messages/_message.html.erb`
- Modify tests: `test/integration/conversation_messages_dual_channel_test.rb`

**Step 1: Expand integration coverage**

- Add test cases:
  - refresh replaces terminal message wrapper with markdown-rendering content
  - refresh is safe for non-terminal (may return placeholder, but must not 500)

**Step 2: Verify the “replace before placeholder exists” race is handled**

- Confirm `app/javascript/lib/turbo_stream_buffer.js` buffers `replace/update` for `message_*` targets and flushes on DOM appearance.

---

### Task 6: UX state machine — stop/retry/stuck/error (required)

**Files:**
- Verify/Modify: `app/javascript/controllers/conversation_channel_controller.js`
- Verify/Modify: `app/views/conversations/show.html.erb`
- Verify/Modify: `app/models/event.rb`
- Add test(s): expand E2E or integration where feasible

**Step 1: Stop hides when terminal; retry shows only on errored**

- Confirm behavior is driven by:
  - realtime `node_state` events, and
  - durable `messages/refresh` fallback.

**Step 2: Stuck detection**

- Confirm warning triggers after 30s without events while active.

---

### Task 7: Layouts/pages acceptance (required)

**Files:**
- Layouts:
  - `app/views/layouts/landing.html.erb`
  - `app/views/layouts/agent.html.erb`
  - `app/views/layouts/settings.html.erb`
- Controllers:
  - `app/controllers/dashboard_controller.rb`
  - `app/controllers/settings/*`
  - `app/controllers/system/settings/*`
- Views:
  - `app/views/dashboard/show.html.erb`

**Step 1: Verify routing uses the correct layout per surface**

- Home uses `landing`
- Conversations uses `agent`
- Dashboard + settings surfaces use `settings`

**Step 2: Verify minimal page content exists**

- Dashboard: meaningful status cards (minimal is fine)
- `/settings`: profile + sessions surfaces render
- `/system/settings`: provider + agent program management surfaces render

---

### Task 8: Observability + hardening (required)

**Files:**
- Verify/Modify: `app/channels/conversation_channel.rb`
- Verify/Modify: `app/models/event.rb`
- Verify/Modify: `app/controllers/concerns/rate_limitable.rb`
- Verify/Modify: `app/controllers/conversations_controller.rb`, `app/controllers/conversation_messages_controller.rb`

**Step 1: Rate-limited warnings**

- Ensure failures are visible in logs (no silent stalls):
  - broadcast failures (already rate-limited)
  - poll fallback errors (already rate-limited)

**Step 2: Throttling**

- Confirm create/stop/retry endpoints are throttled per user and safe for common cache stores.

---

### Task 9: Performance backlog (0.5-G, non-blocking but recommended)

**Files:**
- Modify: `app/javascript/lib/turbo_stream_buffer.js`
- Modify: `app/javascript/application.js`
- Modify (optional): chat page DOM to provide a narrower flush scope root

**Step 1: Narrow MutationObserver scope**

- Instead of observing `document.documentElement`, observe the chat messages container (or a provided scope root) when available.
- Keep TTL/max-size eviction.

---

## Verification checklist (local)

- Rails tests (targeted):
  - `env -u CI bin/rails test test/integration/conversation_messages_dual_channel_test.rb`
  - `env -u CI bin/rails test test/channels/conversation_channel_test.rb`
- JS lint (touched files only):
  - `bun run lint:js`
- E2E (optional/on-demand):
  - `bin/e2e` (new)

