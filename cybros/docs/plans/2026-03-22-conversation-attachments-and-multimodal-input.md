# Conversation Attachments And Multimodal Input Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Execution note:** Implement from the Rails app root at `cybros/`. Reference Rails internals from the monorepo root `references/rails/...`; do not assume the app cwd contains `references/`. When executing the plan, use `executing-plans` and keep the work checkpointed task-by-task.

**Goal:** Build first-class conversation attachment support in Cybros so uploaded files always persist to Active Storage, are eagerly prepared into the agent workspace before each step, and images are additionally exposed as multimodal model input only when the selected model supports image input.

**Architecture:** Keep `ConversationAttachment` as the product-owned attachment record and let Active Storage continue to own blob sharing, purge protection, previews, and variants. Add an idempotent preparation layer that persists prepared refs per `RunDraft`, lets `ConversationRun` reuse them through `snapshot["draft"]["id"]`, eagerly materializes/imports attachments before planning/execution, and upgrades the composer/transcript UI so users can upload, inspect, and send attachments with deterministic ordering and clear multimodal gating.

**Tech Stack:** Rails 8, Active Storage, Hotwire/Stimulus, Bun test, Playwright E2E, PostgreSQL 18.

---

## Non-negotiable product rules

- Upload must work even when the selected model does not support image input.
- Image-to-model delivery must be disabled for non-multimodal models, but image files must still upload, render in the transcript, and materialize/import into the workspace like any other file.
- Attachment preparation must be eager and automatic on the main runtime path. The agent should not need to remember to call `transfer_attachments` for ordinary turn execution.
- Workspace paths must be deterministic, human-readable, and stable within a conversation.
- Attachment numbering must stay contiguous and be derived from ordered attachment position at render/submit time, not stored as a separate mutable label.
- Image prompt payloads must use Active Storage derivatives instead of ad hoc image processing code in Cybros.
- Prompt-image derivative failures must degrade to workspace-only attachment behavior. A corrupt or mislabeled image must not fail the whole turn.
- When prompt-image generation fails, Cybros should expose a compact textual fallback in the attachment prompt context so the model can still reason about the missing image attachment the way Codex emits invalid-image placeholders.
- Cybros must define explicit upload limits in app code instead of relying on Active Storage, provider, or remote-runtime failures. Initial implementation target:
  - max `10` attachments per message
  - max `25 MB` per attachment
  - all MIME types may upload; only image attachments may become prompt images
- Breaking schema and behavior changes are allowed. Prefer correctness over compatibility. If schema drift gets in the way, edit recent migrations and run `bin/rails db:reset`.

## Target data flow

1. User picks files in the composer.
2. `Conversation#append_user_message!` persists ordered `ConversationAttachment` rows plus Active Storage blobs.
3. Before planning or execution for that turn, Cybros eagerly prepares attachments:
   - bundled/local runtime: copy originals into the conversation workspace
   - external runtime: call `attachments.import` and persist returned remote refs
4. Prompt/context assembly receives an enriched manifest with:
   - stable attachment number
   - content metadata
   - prepared workspace/import ref
   - image prompt URL only when the selected model supports image input
5. The transcript UI shows attachment chips/previews for the user turn.

## File ownership

- Upload constraints and attachment model semantics:
  - `app/models/conversation.rb`
  - `app/models/conversation_attachment.rb`
- Upload persistence and manifest shape:
  - `app/services/conversations/attachment_manifest_builder.rb`
- Eager preparation and persistent refs:
  - `app/models/conversation_attachment_preparation.rb` (new)
  - `app/services/conversations/attachment_preparation_service.rb` (new)
  - `app/services/conversations/attachment_transfer_service.rb`
- Prompt/runtime integration:
  - `app/services/run_drafts/conversation_turn_planning_service.rb`
  - `lib/cybros/programmable_agent_provider.rb`
  - `lib/cybros/llm/capability_gated_provider.rb`
  - `lib/cybros/agent_runtime_resolver.rb`
  - `app/models/agent.rb`
- UI:
  - `app/views/conversations/show.html.erb`
  - `app/views/conversation_messages/_message.html.erb`
  - `app/javascript/controllers/message_form_controller.js`
  - `lib/cybros/agent_runtime_resolver.rb`
  - `app/assets/builds/application.js` only via normal build output, never hand-edit
- Tests:
  - `test/models/conversation_attachment_test.rb`
  - `test/models/conversation_attachment_preparation_test.rb` (new)
  - `test/services/conversations/attachment_manifest_builder_test.rb`
  - `test/services/conversations/attachment_preparation_service_test.rb` (new)
  - `test/services/conversations/attachment_prompt_image_service_test.rb` (new)
  - `test/integration/conversation_attachment_upload_gate_test.rb`
  - `test/integration/default_agent_attachment_transfer_test.rb`
  - `test/integration/external_agent_attachment_transfer_test.rb`
  - `test/integration/attachment_prompt_injection_test.rb`
  - `test/integration/programmable_agent_execution_context_test.rb`
  - `test/js/message_form_controller.test.js`
  - `test/e2e/programmable_agent_conversation_attachments.spec.ts` (new)

### Task 0: Lock the upload constraints and fixture baseline before changing runtime behavior

**Files:**
- Create: `test/fixtures/files/attachment-image.png`
- Modify: `app/models/conversation.rb`
- Modify: `app/models/conversation_attachment.rb`
- Modify: `test/models/conversation_attachment_test.rb`
- Modify: `test/integration/conversation_attachment_upload_gate_test.rb`

**Step 1: Write the failing tests**

- Add model coverage for `ConversationAttachment#image?` and for rejecting malformed prompt-image assumptions on non-image fixtures.
- Add integration coverage for the explicit upload limits:
  - too many attachments in one message are rejected
  - oversized attachments are rejected before DAG mutation
- Replace any "text file pretending to be png" test setup with a real image fixture so later Active Storage variant work exercises real image bytes.

**Step 2: Run the failing tests**

Run:

```bash
bin/rails test test/models/conversation_attachment_test.rb test/integration/conversation_attachment_upload_gate_test.rb
```

Expected:

- FAIL because explicit upload limits and real-image semantics are not implemented yet.

**Step 3: Implement the baseline constraints**

- Add explicit attachment count and size validation at the conversation boundary.
- Keep MIME acceptance broad; only image-specific behavior should depend on `ConversationAttachment#image?`.
- Add the real PNG fixture that later integration and E2E tests will reuse.

**Step 4: Run the tests again**

Run:

```bash
bin/rails test test/models/conversation_attachment_test.rb test/integration/conversation_attachment_upload_gate_test.rb
```

Expected:

- PASS.

**Step 5: Commit**

```bash
git add app/models/conversation.rb app/models/conversation_attachment.rb test/models/conversation_attachment_test.rb test/integration/conversation_attachment_upload_gate_test.rb test/fixtures/files/attachment-image.png
git commit -m "test: lock attachment constraints and real image fixtures"
```

### Task 1: Replace the incorrect upload gate with attachment-runtime capability checks

**Files:**
- Modify: `app/models/conversation.rb`
- Modify: `app/models/agent.rb`
- Modify: `app/models/recognized_deployment.rb`
- Test: `test/integration/conversation_attachment_upload_gate_test.rb`
- Test: `test/integration/default_agent_attachment_transfer_test.rb`

**Step 1: Write the failing integration tests**

- Add a test proving bundled claw accepts attachments even when it does not advertise `attachments.import`.
- Add a test proving a non-multimodal selected model still accepts uploaded image files during message creation, and that multimodal suppression remains a provider-time concern rather than an upload-time concern.

**Step 2: Run the failing tests**

Run:

```bash
bin/rails test test/integration/conversation_attachment_upload_gate_test.rb test/integration/default_agent_attachment_transfer_test.rb
```

Expected:

- Current upload gate fails for bundled/local materialization-only agents.

**Step 3: Replace `supports_upload?` with explicit attachment preparation capabilities**

- Add `Agent#supports_workspace_attachment_materialization?`.
- Add `Agent#supports_remote_attachment_import?`.
- Add `Agent#supports_conversation_attachments?` as the union of the two.
- Change `Conversation#validate_attachment_upload_support!` into `validate_attachment_support!` and gate on attachment preparation capability, not image/model capability.
- Keep model image capability checks out of message creation.

**Step 4: Run the tests again**

Run:

```bash
bin/rails test test/integration/conversation_attachment_upload_gate_test.rb test/integration/default_agent_attachment_transfer_test.rb
```

Expected:

- PASS.

**Step 5: Commit**

```bash
git add app/models/conversation.rb app/models/agent.rb app/models/recognized_deployment.rb test/integration/conversation_attachment_upload_gate_test.rb test/integration/default_agent_attachment_transfer_test.rb
git commit -m "refactor: gate attachments by runtime preparation capability"
```

### Task 2: Add persistent prepared refs for eager attachment materialization/import

**Files:**
- Create: `app/models/conversation_attachment_preparation.rb`
- Create: `app/services/conversations/attachment_preparation_service.rb`
- Modify: `app/services/conversations/attachment_transfer_service.rb`
- Modify: `app/services/conversations/attachment_manifest_builder.rb`
- Modify: `app/models/conversation_attachment.rb`
- Modify: `db/migrate/*conversation_attachment*`
- Create: `test/models/conversation_attachment_preparation_test.rb`
- Create: `test/services/conversations/attachment_preparation_service_test.rb`
- Test: `test/integration/default_agent_attachment_transfer_test.rb`
- Test: `test/integration/external_agent_attachment_transfer_test.rb`

**Step 1: Write the failing tests**

- Add a test that eager preparation persists local workspace refs for bundled/local runs.
- Add a test that eager preparation persists remote import refs for external runs and reuses them on retry within the same `RunDraft`.
- Add a test that a `ConversationRun` execution reuses planning-prepared refs by resolving the originating run draft id from `conversation_run.snapshot["draft"]["id"]`.
- Add a test that attachment order in the prepared manifest always matches user upload order.

**Step 2: Run the failing tests**

Run:

```bash
bin/rails test \
  test/models/conversation_attachment_preparation_test.rb \
  test/services/conversations/attachment_preparation_service_test.rb \
  test/integration/default_agent_attachment_transfer_test.rb \
  test/integration/external_agent_attachment_transfer_test.rb
```

Expected:

- FAIL because there is no persistent prepared-ref model and preparation is tool-driven only.

**Step 3: Add the preparation record**

- Create `conversation_attachment_preparations` with:
  - `conversation_attachment_id`
  - `run_draft_id`
  - `recognized_deployment_id`
  - `transfer_mode`
  - `status`
  - `prepared_ref` JSON
  - `prepared_at`
  - uniqueness on `[conversation_attachment_id, run_draft_id]`
- Add model validations and convenience readers.

**Step 4: Implement the eager preparation service**

- `AttachmentPreparationService.ensure_prepared!(conversation:, source_message_node_id:, run_draft:)` should:
  - load ordered attachments for the source user node
  - find or create preparation rows
  - materialize/import missing rows
  - verify that an existing local workspace ref still exists before reusing it
  - return an ordered manifest with `prepared_ref`
- Add a small execution-path adapter that resolves `run_draft_id` from `ConversationRun.snapshot["draft"]["id"]` and delegates to the same service.
- Reuse `AttachmentTransferService` logic internally instead of duplicating transport behavior.
- Keep `transfer_attachments` as a debug/recovery tool, but make it delegate to the new service where possible.

**Step 5: Make workspace paths deterministic**

- Replace `attachments/<uuid>-filename` with:
  - `attachments/<source_message_node_id>/<NN>-<slug>__<shortid>.<ext>`
- Define `shortid` as the first `8` safe characters of `conversation_attachment.id`; this is short enough to stay readable and stable, but still disambiguates duplicate filenames in a single turn.
- Write a per-turn `attachments/<source_message_node_id>/manifest.json` into the conversation workspace for local runs.

**Step 6: Run the tests again**

Run:

```bash
bin/rails test \
  test/models/conversation_attachment_preparation_test.rb \
  test/services/conversations/attachment_preparation_service_test.rb \
  test/integration/default_agent_attachment_transfer_test.rb \
  test/integration/external_agent_attachment_transfer_test.rb
```

Expected:

- PASS.

**Step 7: Reset the database if migration churn is simpler**

Run when needed:

```bash
bin/rails db:reset
```

Expected:

- clean schema matching the new preparation model.

**Step 8: Commit**

```bash
git add app/models/conversation_attachment_preparation.rb app/services/conversations/attachment_preparation_service.rb app/services/conversations/attachment_transfer_service.rb app/services/conversations/attachment_manifest_builder.rb app/models/conversation_attachment.rb test/models/conversation_attachment_preparation_test.rb test/services/conversations/attachment_preparation_service_test.rb db/migrate
git commit -m "feat: persist eager attachment preparation refs"
```

### Task 3: Move image resizing to Active Storage variants and keep original files in the workspace

**Files:**
- Modify: `app/models/conversation_attachment.rb`
- Create: `app/services/conversations/attachment_prompt_image_service.rb`
- Modify: `lib/cybros/programmable_agent_provider.rb`
- Modify: `test/integration/attachment_prompt_injection_test.rb`
- Create: `test/services/conversations/attachment_prompt_image_service_test.rb`
- Test: `test/integration/attachment_prompt_injection_test.rb`

**Step 1: Write the failing tests**

- Add service-level tests using the real PNG fixture:
  - valid image attachments produce an Active Storage representation/proxy URL
  - non-image attachments produce no prompt image
  - corrupt or unrepresentable image attachments degrade to nil instead of failing the turn
- Add a test that image attachments use an Active Storage proxy/representation URL for prompt injection instead of the original blob download URL.
- Add a test that non-image attachments never produce image blocks.
- Add a test that non-multimodal models receive attachment text plus prepared refs but no image blocks.

**Step 2: Run the failing tests**

Run:

```bash
bin/rails test test/services/conversations/attachment_prompt_image_service_test.rb test/integration/attachment_prompt_injection_test.rb
```

Expected:

- FAIL because the current code injects original signed blob URLs and does not distinguish model capability cleanly enough.

**Step 3: Implement prompt image variants with Active Storage**

- Add `ConversationAttachment#image?`.
- Add `ConversationAttachment#prompt_image_representation` using Active Storage native transforms:
  - default derivative: `resize_to_limit: [1000, 1000]`
  - keep source/original file in workspace untouched
  - centralize any format/quality choice in the prompt-image service; prefer a prompt-safe lossy derivative only when the underlying processor supports it cleanly
- Generate prompt URLs via representation proxy helpers, not raw blob download URLs.
- Rescue unrepresentable/corrupt image failures and omit `prompt_image_url` for that attachment instead of aborting the whole step.
- Add a compact textual fallback for failed image prompt generation, for example: attachment exists, path/prepared ref is valid, but multimodal image forwarding was skipped because the image could not be represented safely.
- Do not create a custom reference-count table for variants; rely on Active Storage blob/attachment semantics.

**Step 4: Run the tests again**

Run:

```bash
bin/rails test test/services/conversations/attachment_prompt_image_service_test.rb test/integration/attachment_prompt_injection_test.rb
```

Expected:

- PASS.

**Step 5: Commit**

```bash
git add app/models/conversation_attachment.rb app/services/conversations/attachment_prompt_image_service.rb lib/cybros/programmable_agent_provider.rb test/services/conversations/attachment_prompt_image_service_test.rb test/integration/attachment_prompt_injection_test.rb
git commit -m "feat: serve prompt images through active storage variants"
```

### Task 4: Eagerly prepare attachments on the real planning and execution path

**Files:**
- Modify: `app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `lib/cybros/programmable_agent_provider.rb`
- Modify: `app/services/conversations/attachment_manifest_builder.rb`
- Test: `test/integration/programmable_agent_execution_context_test.rb`
- Test: `test/integration/programmable_agent_hooks_test.rb`

**Step 1: Write the failing tests**

- Add a planning-path test proving `before_agent_step` receives prepared refs in `attachment_manifest`.
- Add an execution-path test proving provider input contains prepared refs before the first LLM/tool call.
- Add a retry test proving the second execution reuses persisted preparation rows rather than reimporting unnecessarily.

**Step 2: Run the failing tests**

Run:

```bash
bin/rails test test/integration/programmable_agent_execution_context_test.rb test/integration/programmable_agent_hooks_test.rb
```

Expected:

- FAIL because planning/execution currently expose only the bare manifest.

**Step 3: Call eager preparation from both runtime entry points**

- In `RunDrafts::ConversationTurnPlanningService#prepare_params`, call the new preparation service and include `prepared_ref` in the manifest.
- In `Cybros::ProgrammableAgentProvider`, prepare attachments before:
  - building hook payloads
  - augmenting the last user message
- Reuse the originating `run_draft_id` from `ConversationRun.snapshot["draft"]["id"]`; do not introduce a second execution-only preparation scope.
- Keep the preparation call idempotent and cheap when rows already exist.

**Step 4: Upgrade the manifest shape**

- Every attachment entry should include:
  - `id`
  - `position`
  - `filename`
  - `content_type`
  - `byte_size`
  - `digest`
  - `kind`
  - `prepared_ref`
  - `prompt_image_url` only when both `image?` and `model_supports_images?`

**Step 5: Run the tests again**

Run:

```bash
bin/rails test test/integration/programmable_agent_execution_context_test.rb test/integration/programmable_agent_hooks_test.rb
```

Expected:

- PASS.

**Step 6: Commit**

```bash
git add app/services/run_drafts/conversation_turn_planning_service.rb lib/cybros/programmable_agent_provider.rb app/services/conversations/attachment_manifest_builder.rb test/integration/programmable_agent_execution_context_test.rb test/integration/programmable_agent_hooks_test.rb
git commit -m "feat: eagerly prepare attachments before planning and execution"
```

### Task 5: Finish the composer and transcript UI

**Files:**
- Modify: `app/views/conversations/show.html.erb`
- Modify: `app/views/conversation_messages/_message.html.erb`
- Modify: `app/javascript/controllers/message_form_controller.js`
- Modify: `lib/cybros/agent_runtime_resolver.rb`
- Modify: `test/js/message_form_controller.test.js`
- Create: `test/e2e/programmable_agent_conversation_attachments.spec.ts`

**Step 1: Write the failing JS and E2E tests**

- Add JS tests for:
  - selected attachment chips/previews render in the composer
  - removing an attachment updates the selection token
  - changing the selected model toggles image-vision messaging without clearing the files
- Add Playwright coverage for:
  - upload a text file and send it
  - upload an image and send it
  - switch from multimodal to non-multimodal model and confirm the upload remains but the UI shows vision-disabled behavior

**Step 2: Run the failing tests**

Run:

```bash
bun test test/js/message_form_controller.test.js
```

Run after the app is available:

```bash
bin/e2e test/e2e/programmable_agent_conversation_attachments.spec.ts
```

Expected:

- FAIL because the UI currently has only a hidden file input and no usable attachment presentation.

**Step 3: Add attachment UI to the composer**

- Extend model option payloads so the selected option carries `supports_images` metadata into the DOM.
- Show pending attachment pills above the textarea.
- Add remove buttons per attachment.
- Render image thumbnails for image files.
- Keep the hidden file input, but make the state visible and keyboard-safe.
- Use `<template>` + `cloneNode` patterns in Stimulus for repeated attachment UI instead of HTML string building.
- Add model capability messaging:
  - multimodal model: image attachments will be sent to the model and copied/imported to the workspace
  - non-multimodal model: image attachments will upload and reach the workspace only

**Step 4: Add transcript rendering**

- For user messages, render image attachments with thumbnail previews.
- Render non-image attachments as richer file cards showing filename, content type, and size.
- Preserve upload order from the stored manifest.

**Step 5: Run the JS tests again**

Run:

```bash
bun test test/js/message_form_controller.test.js
```

Expected:

- PASS.

**Step 6: Commit**

```bash
git add app/views/conversations/show.html.erb app/views/conversation_messages/_message.html.erb app/javascript/controllers/message_form_controller.js lib/cybros/agent_runtime_resolver.rb test/js/message_form_controller.test.js test/e2e/programmable_agent_conversation_attachments.spec.ts
git commit -m "feat: add attachment composer and transcript ui"
```

### Task 6: End-to-end verification across unit, integration, E2E, and real dev mode

**Files:**
- No new product files unless fixes are required.
- Verification notes may be appended to this plan or a follow-up ledger.

**Step 1: Run targeted Rails tests**

Run:

```bash
bin/rails test \
  test/models/conversation_attachment_test.rb \
  test/models/conversation_attachment_preparation_test.rb \
  test/services/conversations/attachment_manifest_builder_test.rb \
  test/services/conversations/attachment_preparation_service_test.rb \
  test/services/conversations/attachment_prompt_image_service_test.rb \
  test/integration/conversation_attachment_upload_gate_test.rb \
  test/integration/default_agent_attachment_transfer_test.rb \
  test/integration/external_agent_attachment_transfer_test.rb \
  test/integration/attachment_prompt_injection_test.rb \
  test/integration/programmable_agent_execution_context_test.rb \
  test/integration/programmable_agent_hooks_test.rb
```

Expected:

- PASS.

**Step 2: Run JS unit tests**

Run:

```bash
bun test test/js/message_form_controller.test.js
```

Expected:

- PASS.

**Step 3: Run full app tests for regression confidence**

Run:

```bash
bin/rails test
```

Expected:

- PASS.

**Step 4: Run E2E against the dev app**

Start prerequisites:

```bash
# Start PostgreSQL first if your local machine is not already running it.
# Ubuntu snapshot example: sudo pg_ctlcluster 18 main start
# If Playwright browsers are missing: bunx playwright install
bin/dev
```

In another shell:

```bash
bin/e2e test/e2e/programmable_agent_conversation_attachments.spec.ts
```

Expected:

- PASS.

**Step 5: Perform manual acceptance in the real dev app**

Manual script:

1. Open `http://localhost:3000`.
2. Sign in.
3. Open a conversation using a multimodal model.
4. Upload one text file and one image.
5. Confirm the composer shows both files before send.
6. Send the turn and confirm the transcript shows both attachments in order.
7. Verify the conversation workspace contains the materialized originals under the deterministic attachment path.
8. Verify the agent receives prepared refs in planning/execution logs.
9. Switch to a non-multimodal model.
10. Upload another image and send.
11. Confirm the UI explains the image is workspace-only for that model.
12. Confirm the upload still persists and materializes/imports correctly.
13. Confirm no image block is sent to the provider for the non-multimodal turn.

**Step 6: Fix any failures, rerun the smallest affected test first, then rerun the full gate**

Run as needed:

```bash
bin/rails test path/to/failing_test.rb
bun test test/js/message_form_controller.test.js
bin/e2e test/e2e/programmable_agent_conversation_attachments.spec.ts
```

**Step 7: Final commit**

```bash
git add .
git commit -m "feat: ship conversation attachments and multimodal image input"
```

## Explicit design choices to preserve during implementation

- Do not copy Codex literally. Copy the successful invariants:
  - stable per-turn attachment numbering
  - files available via deterministic paths
  - images are a separate multimodal channel, not inlined text
  - pruning/removal preserves contiguous ordering
  - invalid local images degrade to explicit text diagnostics rather than failing the entire request
- Reuse planning-prepared refs during execution through the draft snapshot; do not fork separate preparation state for planning and execution unless a concrete runtime bug forces it.
- Do not create a second blob ownership system. Active Storage already gives shared blobs plus purge protection through `active_storage_attachments`.
- Do not block uploads based on model multimodality.
- Do not require the agent to explicitly opt into attachment preparation on the happy path.
- Do not keep the current "original blob signed URL" prompt image behavior.

## Acceptance checklist

- User can upload multiple files from the composer.
- Uploaded files appear in the composer before send and in the transcript after send.
- Attachments persist to Active Storage and ordered `ConversationAttachment` rows.
- Attachments are eagerly materialized/imported before planning/execution.
- Local workspace paths are deterministic and human-readable.
- External runtime imports persist returned refs and are reused idempotently within the same draft/execution scope.
- Multimodal models receive image prompt blocks derived from Active Storage variants.
- Corrupt or unrepresentable images degrade to workspace-only attachments instead of failing the turn.
- Non-multimodal models receive no image prompt blocks, but the same files still upload and prepare successfully.
- Unit tests, integration tests, E2E tests, and `bin/dev` manual validation all pass.
