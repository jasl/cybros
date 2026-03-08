# Conversation Model Picker Provider Groups Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Group the conversation composer model picker by provider while keeping the existing native DaisyUI `select` control.

**Architecture:** Keep `Cybros::AgentRuntimeResolver.usable_model_options` as the source of truth, extend each option with a provider-local display name, and build grouped data in `ConversationsController#show`. Render grouped options with native `<optgroup>` tags in the conversation view so the picker stays simple, accessible, and form-compatible.

**Tech Stack:** Rails 8, ERB, Tailwind CSS 4, DaisyUI 5, Minitest integration tests

---

### Task 1: Lock the HTML contract with an integration test

**Files:**
- Modify: `cybros/test/integration/conversations_test.rb`

**Step 1: Write the failing test**

Add an integration test that signs in, enables multiple providers, renders the conversation page, and asserts:
- the composer model picker contains `optgroup` sections for provider display names
- duplicate labels such as `GPT‑5.4` appear within their groups without provider suffixes in the option text

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/conversations_test.rb`
Expected: FAIL because the current picker renders a flat list of `<option>` elements.

### Task 2: Implement grouped picker data and rendering

**Files:**
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/app/views/conversations/show.html.erb`

**Step 1: Extend model options with a provider-local label**

Keep the existing `label` field for flat consumers, and add a raw `model_display_name` field for grouped consumers.

**Step 2: Build provider groups in the conversation controller**

Group usable options by provider in first-seen order and expose that grouped structure to the view.

**Step 3: Render native optgroups in the conversation picker**

Replace the flat option loop with `<optgroup>` sections using DaisyUI’s existing `select` styling.

### Task 3: Verify behavior

**Files:**
- Test: `cybros/test/integration/conversations_test.rb`

**Step 1: Run targeted test to verify it passes**

Run: `bin/rails test test/integration/conversations_test.rb`
Expected: PASS for the new provider-grouped picker assertions.

**Step 2: Run any adjacent targeted test if needed**

Run: `bin/rails test test/integration/model_picker_credential_gating_test.rb`
Expected: PASS to confirm credential gating still works with grouped options.
