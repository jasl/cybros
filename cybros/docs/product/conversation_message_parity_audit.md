# Conversation/Message parity audit (TavernKit playground → Cybros)

This document summarizes the current parity status between TavernKit playground’s conversation/message features and Cybros’ `Conversation` + DAG-based chat model.

## Scope

- **In-scope (requested parity)**: conversation tree/branching, regenerate + swipe, translation (metadata + clearing), exclude/include from context, soft delete/restore with “stop generating” safety, message projection + pagination, and basic authorization.
- **Out-of-scope (documented non-goals for this refactor)**: TavernKit’s Space/Membership model, TurnScheduler + ConversationRound state machine, and the legacy `Message` table as a source-of-truth.

## Parity matrix

| Capability | TavernKit spec (tests/services) | Cybros implementation | Cybros coverage | Status |
|---|---|---|---|---|
| Conversation tree fields (`kind`, parent/root, fork point) | `test/controllers/conversations_controller_test.rb` (branch tests); `test/services/messages/hider_test.rb` (“does not hide fork point messages”) | `Conversation` tree columns + `Conversation#create_child!` / `forked_from_node_id` in `app/models/conversation.rb` | `test/models/conversation_tree_test.rb`, `test/integration/conversation_branching_test.rb`, `test/models/conversation_chat_facade_test.rb` | Covered |
| Branch from a message/node | `conversations_controller_test.rb` “branch creates…” | `POST /conversations/:id/branch` + `Conversation#create_child!` | `test/integration/conversation_branching_test.rb` | Covered (prefix-copy semantics differ; Cybros forks DAG lane instead of copying rows) |
| Regenerate on tail assistant (in-place) | `conversations_controller_test.rb` regenerate tests | `Conversation#regenerate!` creates swipe variant node | `test/integration/conversation_regenerate_swipe_test.rb`, `test/models/conversation_chat_facade_test.rb` | Covered (storage model differs) |
| Regenerate on non-tail assistant (auto-branch) | `conversations_controller_test.rb` regenerate non-tail behavior | `Conversation#regenerate!` branches when target isn’t current tail | `test/integration/conversation_regenerate_swipe_test.rb` | Covered |
| Swipe selection and context behavior | `conversations_controller_test.rb` + swipe model semantics | `Conversation#select_swipe!` uses DAG versions (`version_set_id` + `adopt_version!`) | `test/models/conversation_chat_facade_test.rb`, `test/integration/conversation_regenerate_swipe_test.rb` | Covered (DAG multi-version; no `MessageSwipe` table) |
| Exclude/include from context | (implicit in prompt building; plus UI actions) | `Conversation#exclude_node!` / `include_node!` and DAG visibility rules | `test/integration/conversation_node_visibility_test.rb`, `test/models/conversation_context_test.rb` | Covered |
| Soft delete/restore (visibility) | `messages_controller_test.rb` destroy tests; `Messages::Hider` semantics | `Conversation#soft_delete_node!` / `restore_node!` backed by `dag_nodes.deleted_at` / visibility patches | `test/integration/conversation_soft_delete_test.rb`, `test/models/dag/visibility_patches_test.rb` | Covered |
| Soft delete rollback safety (“stop generating”, downstream cancel) | `test/services/messages/hider_test.rb` (queued/running cancel + fork point protection) | `Conversation#soft_delete_node!` stops downstream work **only when deleting head or trigger**, cancels associated `ConversationRun`s | `test/models/conversation_soft_delete_rollback_test.rb` | Covered (DAG-native; no Round/TurnScheduler) |
| Linear message projection (timeline) | TavernKit `Message` is source-of-truth | `DAG::TranscriptProjection` + `DAG::Lane#message_page` | `test/models/conversation_chat_facade_test.rb` (“projection hides non-selected swipes”), `test/models/conversation_context_test.rb` | Covered (projection, not a DB `messages` table) |
| Pagination (before cursor) | TavernKit message seq-based paging | `Lane#message_page` + controller cursors | `test/integration/conversation_pagination_test.rb` | Covered |
| Authorization boundaries | TavernKit membership-based | `Current.user.conversations` scoping | `test/integration/conversation_authorization_test.rb` | Covered |
| Translation trigger semantics (mode gating + job enqueue) | `test/controllers/messages_controller_test.rb` (mode=off, internal_lang==target_lang, enqueues job) | `Conversation#translate!` only sets `metadata.i18n.translation_pending[target_lang]` | `test/models/conversation_chat_facade_test.rb` | Partial (no mode gating, no job/run model yet) |
| Clear translations cancels translation runs | `conversations_controller_test.rb` clear_translations + TranslationRun cancellation | `Conversation#clear_translations!` clears metadata for lane nodes | `test/controllers/conversations_controller_test.rb` equivalent **not present** in Cybros | Partial |
| Message editing / inline edit constraints | `test/controllers/messages_controller_test.rb` (tail-only edit/update) | No equivalent UI/controller today | None | Missing (explicit non-goal) |
| TurnScheduler/Rounds (retry stuck run, cancel stuck run, auto modes) | Large portions of `conversations_controller_test.rb` + scheduler services | DAG tick/scheduler exists but no Round model | Some DAG scenario tests | Missing (explicit non-goal) |

## Notes

- Search/index tools exclude `references/` (gitignored) content, so the TavernKit citations above are based on direct file reads of the referenced test/service files.
