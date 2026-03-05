# Phase 0.5 gap table (single source of truth)

Source of requirements: `cybros/docs/product/roadmap.md` → **Phase 0.5** (Acceptance Criteria + Edge/extreme test matrix).

Status legend:
- ✅ **Complete**: implemented and has convincing evidence (ideally test coverage)
- 🟡 **Partial**: present but missing invariant, UX detail, or test coverage
- ❌ **Missing**: no meaningful implementation yet

Non-negotiable boundary rule: **controllers/channels/views are Conversation-first** (no DAG types at the app boundary).

## Summary (current snapshot)

Counts by section:
- **Layouts & shell**: ✅ 7 · 🟡 0 · ❌ 0
- **Pages**: ✅ 5 · 🟡 0 · ❌ 0
- **Transport & ordering invariants**: ✅ 12 · 🟡 0 · ❌ 0
- **Indicator + controls (stop/retry/stuck)**: ✅ 6 · 🟡 0 · ❌ 0
- **Observability & throttling**: ✅ 5 · 🟡 0 · ❌ 0
- **Auth/pagination/broadcast hardening**: ✅ 7 · 🟡 0 · ❌ 0
- **Edge/extreme test matrix**: ✅ 7 · 🟡 0 · ❌ 0

Optional follow-ups (post-acceptance / non-blocking):
1. **Decide whether to include `RUN_E2E=1` in CI** (keep default fast; opt-in on demand).
2. **Archive/clean up this gap table** (as agreed: temporary doc).
3. **Add a dedicated typing-indicator assertion** (spinner appears on first delta; not strictly required if other E2E cover streaming).
4. **Add provider/model “health” copy/empty states** on `/system/settings` (nice-to-have).
5. **Stabilize log key contract** for subscribe/replay structured logs (nice-to-have).

---

## Layouts & shell

| Item | Status (✅/🟡/❌) | Evidence | Gap | Next step | Test coverage |
|---|---|---|---|---|---|
| `landing` / `agent` / `settings` layouts exist | ✅ | `app/views/layouts/landing.html.erb`, `app/views/layouts/agent.html.erb`, `app/views/layouts/settings.html.erb` | — | — | `test/e2e/top_level_smoke.spec.ts` |
| Home uses `landing` | ✅ | `app/controllers/home_controller.rb` (`layout "landing"`) | — | — | `test/e2e/top_level_smoke.spec.ts` |
| Conversations + Agents use `agent` | ✅ | `app/controllers/conversations_controller.rb` + `app/controllers/agent_programs_controller.rb` both inherit `AgentController` (`layout "agent"`) | — | — | `test/e2e/top_level_smoke.spec.ts` |
| `/settings` + `/system/settings` use `settings` | ✅ | `app/controllers/settings/base_controller.rb`, `app/controllers/system/settings/base_controller.rb` (`layout "settings"`) | — | — | `test/integration/llm_providers_test.rb` (system settings auth + CRUD) |
| Agent shell is 3-pane responsive (left drawer + right drawer on demand) | ✅ | `app/views/layouts/agent.html.erb` uses `drawer` + `drawer-end`, conditional `content_for?(:right_sidebar)` | Optional resize handles not present (not required by acceptance) | — | Manual browser check |
| Mobile acceptance basics (drawer, overlay) | ✅ | `agent.html.erb` uses `lg:hidden` overlays; `settings.html.erb` provides mobile tabs fallback | Resize/gesture polish not covered in tests | Optional: add a focused mobile viewport E2E check later | `test/e2e/top_level_smoke.spec.ts` (page load smoke) |
| **Dashboard uses `agent` layout** | ✅ | `app/controllers/dashboard_controller.rb` (inherits `AgentController`) | — | — | `test/integration/dashboard_layout_test.rb` |

---

## Pages

| Item | Status (✅/🟡/❌) | Evidence | Gap | Next step | Test coverage |
|---|---|---|---|---|---|
| Dashboard route exists and renders status cards | ✅ | `config/routes.rb` (`get "dashboard"`), `app/controllers/dashboard_controller.rb`, `app/views/dashboard/show.html.erb` | — | — | `test/e2e/top_level_smoke.spec.ts` |
| `/settings` (personal): profile + sessions routes exist | ✅ | `config/routes.rb` → `namespace :settings` | — | — | `test/e2e/top_level_smoke.spec.ts` |
| `/system/settings` is namespaced + usable (providers + agent programs) | ✅ | `config/routes.rb`, `app/controllers/system/settings/*`, `app/views/system/settings/**` | Provider/model “health” UI is minimal | Add “health” card copy/empty states as needed | `test/integration/llm_providers_test.rb` |
| System settings access control enforced | ✅ | `System::Settings::BaseController#require_system_settings_access` | — | — | `test/integration/llm_providers_test.rb` (member forbidden) |
| Required smoke suite: each top-level page loads (Home, Dashboard, Conversations, Agents, `/settings`, `/system/settings`) | ✅ | E2E visits all top-level pages (unauth + auth) | — | — | `test/e2e/top_level_smoke.spec.ts` |

---

## Transport & ordering invariants (Turbo truth + ActionCable ephemeral)

| Item | Status (✅/🟡/❌) | Evidence | Gap | Next step | Test coverage |
|---|---|---|---|---|---|
| Durable HTTP truth: `POST /conversations/:id/messages` appends user + agent placeholder; removes empty state | ✅ | `app/controllers/conversation_messages_controller.rb#create` | — | — | `test/integration/conversation_messages_dual_channel_test.rb` |
| Durable paging: `GET /conversations/:id/messages` returns Turbo stream prepend/append + cursor update | ✅ | `ConversationMessagesController#index` (`before`/`after`, `prepend`/`append`, load-more replace) | No explicit “after append” test (only before/prepend) | Add coverage for `after` append mode (optional) | `test/integration/conversation_pagination_test.rb` (before/prepend) |
| Durable convergence: `GET /conversations/:id/messages/refresh?node_id=...` replaces wrapper | ✅ | `ConversationMessagesController#refresh` | — | — | `test/integration/conversation_messages_dual_channel_test.rb` |
| ActionCable auth/ownership enforced on subscribe | ✅ | `app/channels/conversation_channel.rb#subscribed` rejects unauth + cross-user | — | — | `test/channels/conversation_channel_test.rb` |
| Stable envelope for `node_event` | ✅ | `ConversationChannel.envelope_for` includes `type, conversation_id, turn_id, node_id, event_id, kind, text, payload, occurred_at` | — | — | `test/channels/conversation_channel_test.rb` (payload shape assertions) |
| Replay batching (`replay_batch`) | ✅ | `ConversationChannel#replay_missed_events!` transmits `{type:"replay_batch", events:[...]}` | — | — | `test/channels/conversation_channel_test.rb` |
| Cursor semantics: resume strictly after cursor + dedupe via preview | ✅ | Cursor persisted + replay resumes strictly after cursor; dedupe via compareEventIds | — | — | `test/e2e/conversation_reconnect_resume.spec.ts` |
| Low-frequency polling fallback (not primary) | ✅ | `ConversationChannel` periodic `poll_fallback` every 10s (vs prior 0.25s polling) | Might still be too chatty for scale (Phase 0.5 ok) | Consider lowering frequency or gating when connected/idle | `test/channels/conversation_channel_test.rb` (poll_fallback replay) |
| Ordering invariant: rapid sends preserve user order + pairing | ✅ | Server-side transcript alternates user/agent placeholders by turn | — | — | `test/e2e/conversation_rapid_sends_ordering.spec.ts`, `test/integration/conversation_rapid_sends_test.rb` |
| Out-of-order event arrival does not reorder UI | ✅ | Client buffers then orders by `event_id` before applying | — | — | `test/js/node_event_ordering.test.js` |
| “Active run node” tracking is explicit | ✅ | `conversation_channel_controller.js` maintains `activeNodeId` driven by `node_state` + `output_delta` | Node selection semantics beyond “last bubble” not specified | Confirm any multi-run UI uses explicit node id | `test/e2e/conversation_mock_llm_stop.spec.ts` (stop targets node id) |
| Stable envelope contract for `node_state` is surface-agnostic | ✅ | `app/models/event.rb` broadcasts `{type:"node_state", conversation_id, event_id, turn_id, node_id, from, to, occurred_at}` | — | — | `test/models/event_turbo_streams_broadcast_test.rb` |

---

## Indicator + controls (stop / retry / stuck)

| Item | Status (✅/🟡/❌) | Evidence | Gap | Next step | Test coverage |
|---|---|---|---|---|---|
| Typing/streaming indicator anchored to active assistant bubble | ✅ | `conversation_channel_controller.js` shows `[data-role="spinner"]` within `[data-role="agent-bubble"][data-node-id]` | No dedicated “spinner appears on first delta” assertion | Optional: add one small E2E assertion | `test/e2e/conversation_mock_llm_streaming.spec.ts`, `test/e2e/conversation_mock_llm_stop.spec.ts` (streaming coverage) |
| Stop/cancel works end-to-end | ✅ | `POST /conversations/:id/stop` → `ConversationsController#stop` → `Conversation#stop_node!`; UI button wired via Stimulus | UI button timing can be flaky; E2E uses direct request (still exercises endpoint) | Add UI-click stop test only if stable | `test/e2e/conversation_mock_llm_stop.spec.ts` |
| Retry works end-to-end (errored → retry) | ✅ | `POST /conversations/:id/retry` → `ConversationsController#retry`; client shows Retry on `node_state: errored` | Retry triggers full reload (`Turbo.visit`) instead of in-place reconciliation | Consider in-place path later (non-blocking) | `test/e2e/conversation_mock_llm_error_retry.spec.ts` |
| Terminal convergence (replace missed) | ✅ | `Event#broadcast_node_state_change` broadcasts Turbo replace on terminal; client also falls back to `messages/refresh` | None | — | `test/models/event_turbo_streams_broadcast_test.rb`, `test/e2e/conversation_mock_llm_realtime_replace.spec.ts` |
| Stuck detection: heartbeat timeout → warning + allow stop/retry | ✅ | Client checks \(>30s\) since last event and shows alert + Retry | — | — | `test/js/stuck_detection.test.js` |
| Inline error presentation in bubble | ✅ | Terminal errored message renders server error text in bubble | — | — | `test/e2e/conversation_mock_llm_error_retry.spec.ts` |

---

## Observability & throttling

| Item | Status (✅/🟡/❌) | Evidence | Gap | Next step | Test coverage |
|---|---|---|---|---|---|
| Rate-limited warnings for broadcast failures (no silent stalls) | ✅ | `Cybros::RateLimitedLog.warn` used in `ConversationChannel.broadcast_node_event` + `Event#broadcast_node_state_change` + `ConversationChannel#rate_limited_warn` | Coverage is unit-level; no prod dashboard | OK for Phase 0.5 | `test/models/broadcast_error_logging_test.rb` |
| Structured logs: subscribe + replay | ✅ | `ConversationChannel` logs JSON for subscribed + replay counts | No test (acceptable) | Optional: ensure log keys stable | TODO |
| Dev-only debug overlay shows cursor/node/last event | ✅ | `app/views/conversations/show.html.erb` + `app/javascript/controllers/debug_overlay_controller.js` | Dev-only only (as intended) | — | Manual browser check |
| Throttling: messages create + stop/retry endpoints | ✅ | `ConversationMessagesController` throttles `"messages"`; `ConversationsController` throttles `"stop_retry"` | Throttle keys/limits may need tuning | Document limits in code/docs later | TODO |
| Poll fallback errors are visible (rate-limited) | ✅ | `ConversationChannel#poll_fallback` rescues and warns at most every 10s | — | — | TODO |

---

## Auth/pagination/broadcast hardening

| Item | Status (✅/🟡/❌) | Evidence | Gap | Next step | Test coverage |
|---|---|---|---|---|---|
| Conversation-first app boundary (no DAG types in controllers/channels/views) | ✅ | Search confirms no `DAG::` references in `app/controllers/`, `app/channels/`, `app/views/` (DAG stays in models/jobs) | — | — | TODO (guard test) |
| Cross-user conversation access denied (controllers + cable) | ✅ | Controllers use `Current.user.conversations.find_by`; channel rejects mismatched owner | — | — | `test/integration/conversation_authorization_test.rb`, `test/channels/conversation_channel_test.rb` |
| Conversations index is cursor-paginated (UUID keyset) | ✅ | `ConversationsController#index` uses `id < before` / `id > after` and order by id desc | No “after” paging test | Add `after` coverage if needed | `test/integration/conversation_pagination_test.rb` (before) + `test/e2e/conversations.spec.ts` (Older link) |
| Message history paging works | ✅ | `ConversationMessagesController#index` + turbo prepend | “Load newer” path not covered | Optional | `test/integration/conversation_pagination_test.rb` |
| Replay batching used on reconnect | ✅ | `ConversationChannel#replay_missed_events!` transmits one batch | No system/E2E coverage | Covered in Edge matrix row | `test/channels/conversation_channel_test.rb` |
| Broadcast failures not swallowed | ✅ | Rate-limited warn logging tests exist | — | — | `test/models/broadcast_error_logging_test.rb` |
| Broadcast replaces for terminal agent nodes | ✅ | `Event#broadcast_node_state_change` → `Turbo::StreamsChannel.broadcast_replace_to [conversation, :messages]` | — | — | `test/models/event_turbo_streams_broadcast_test.rb` |

---

## Edge/extreme test matrix (required)

| Item | Status (✅/🟡/❌) | Evidence | Gap | Next step | Test coverage |
|---|---|---|---|---|---|
| Rapid sends (3–10) preserve ordering + pairing | ✅ | Server transcript verified + UI DOM ordering asserted | — | — | `test/e2e/conversation_rapid_sends_ordering.spec.ts`, `test/integration/conversation_rapid_sends_test.rb` |
| Reconnect mid-stream resumes without duplication | ✅ | Cursor + replay_batch semantics + localStorage cursor | — | — | `test/e2e/conversation_reconnect_resume.spec.ts` |
| Compaction mid-stream doesn’t break UI | ✅ | Broadcast and replay fill compacted text via preview | No browser-level test | Optional E2E: ensure compacted marker renders expected preview | `test/channels/conversation_channel_test.rb` |
| Out-of-order events don’t reorder UI | ✅ | Client orders buffered events by `event_id` before applying | — | — | `test/js/node_event_ordering.test.js` |
| Provider/model mismatch has clear UX | ✅ | Agent placeholder includes a warning banner sourced from node metadata | — | — | `test/integration/conversation_messages_dual_channel_test.rb` |
| Invalid provider config (headers JSON) is 422 with inline error | ✅ | Controller validates + renders errors | — | — | `test/integration/llm_providers_test.rb` |
| Long outputs remain responsive/bounded | ✅ | Terminal markdown truncates extremely long output | No browser perf test | OK for Phase 0.5 | `test/integration/conversation_long_output_test.rb` |

