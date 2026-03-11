# Programmable Agent Reaudit Remediation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** repair the programmable-agent rebaseline mismatches found in the 2026-03-10 full audit without widening product scope or reintroducing compatibility shims as permanent architecture.

**Architecture:** fix the hard behavioral regressions first, then close the remaining authority split between `AgentProgram` and legacy `agent_profile` metadata, and only then delete the leftover shims and update docs. Every batch stays TDD-first, keeps changes narrow, and ends with targeted verification before the next batch starts.

**Tech Stack:** Ruby 4.0.1, Rails 8.2 alpha, Active Record migrations, Minitest, programmable-agent host, DAG conversation runtime

---

## Scope

**In scope for this remediation stream**

- subagent ownership and workspace-root correctness
- explicit stale-selection and parked-draft pinning
- operator boundary repairs around `AgentProgram`
- bundled default singleton behavior
- removal of live `default-assistant` / `profile_source` runtime shims
- docs convergence for the programmable-agent source of truth

**Explicit carry-forward, not in the first repair stream**

- provider-credential scoping inside runtime governance
- settings-nav completeness for every operator surface
- richer deployment inspection UI
- automation UI prompt-shape cleanup

Those items are real findings, but they are adjacent to the programmable-agent rebaseline rather than blocking its core authority model.

## Batch Order

1. Batch 1: correctness fixes that currently produce wrong runtime ownership or unsafe filesystem behavior
2. Batch 2: run-lifecycle pinning and stale-selection handling
3. Batch 3: operator-boundary and singleton bundled-default repairs
4. Batch 4: authority unification for default interactive runtime
5. Batch 5: shim deletion and docs convergence

### Task 1: Batch 1A Subagent Children Must Inherit The Launching Program

**Files:**
- Modify: `test/lib/cybros/subagent/tools_test.rb`
- Modify: `test/lib/cybros/subagent/run_wait_tools_test.rb`
- Modify: `test/scenarios/dag/subagent_child_conversation_flow_test.rb`
- Modify: `lib/cybros/subagent/tools.rb`

**Step 1: Write the failing tests**

Add coverage like:

```ruby
test "subagent_spawn pins child to the parent's agent program" do
  parent = create_conversation!(agent_program: forked_program)
  result = spawn_tool.call({ "name" => "child", "prompt" => "hi" }, context: ctx)
  child = Conversation.find(JSON.parse(result.text).fetch("child_conversation_id"))

  assert_equal parent.agent_program_id, child.agent_program_id
  assert_equal parent.agent_config_schema_fingerprint, child.agent_config_schema_fingerprint
end
```

Also add the same assertion path for `subagent_run`.

**Step 2: Run the tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/scenarios/dag/subagent_child_conversation_flow_test.rb`

Expected: FAIL because child conversations currently default to the bundled default program on create.

**Step 3: Write the minimal implementation**

Pass `agent_program:` and `agent_config_schema_fingerprint:` explicitly when `subagent_spawn` and `subagent_run` create child conversations. Keep the metadata payload for observability only; do not use it as the ownership authority.

**Step 4: Run the tests to verify they pass**

Run the same command from Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/scenarios/dag/subagent_child_conversation_flow_test.rb lib/cybros/subagent/tools.rb
git commit -m "fix: preserve agent program across subagent conversations"
```

### Task 2: Batch 1B Custom Workspace Root Must Stop Falling Back To App Root

**Files:**
- Modify: `test/models/runtime_setting_test.rb`
- Modify: `test/services/agent_programs/bootstrap_bundled_default_service_test.rb`
- Modify: `test/integration/system_settings_runtime_settings_test.rb`
- Modify: `test/integration/system_settings_agent_programs_test.rb`
- Modify: `test/integration/forked_agent_execution_test.rb`
- Modify: `app/models/runtime_setting.rb`
- Modify: `app/services/agent_programs/bootstrap_bundled_default_service.rb`
- Modify: `app/services/agent_programs/fork_service.rb`
- Modify: `app/controllers/system/settings/runtime_settings_controller.rb`

**Step 1: Write the failing tests**

Add coverage that proves:

```ruby
test "instance_agent_workspace_root_path rejects Rails.root outside test" do
  RuntimeSetting.delete_all

  assert_raises(AgentCore::ValidationError) do
    AgentPrograms::ForkService.call!(source_program: bundled_program, name: "Forked")
  end
end
```

Add a second test proving bootstrap does not silently seed `agent_workspace_root` to `Rails.root` in development-like environments.

**Step 2: Run the tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/runtime_setting_test.rb test/services/agent_programs/bootstrap_bundled_default_service_test.rb test/integration/system_settings_runtime_settings_test.rb test/integration/system_settings_agent_programs_test.rb test/integration/forked_agent_execution_test.rb`

Expected: FAIL because the current default still normalizes to `Rails.root`.

**Step 3: Write the minimal implementation**

Implement the hard boundary:

- non-test runtime settings must not default custom-agent workspace root to `Rails.root`
- bootstrap must require an explicit non-app-root workspace root before enabling fork/custom-source flows
- fork flow must raise a structured validation error instead of copying into app-root
- keep test environment on a dedicated tmp root so test ergonomics stay intact

**Step 4: Run the tests to verify they pass**

Run the same command from Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add test/models/runtime_setting_test.rb test/services/agent_programs/bootstrap_bundled_default_service_test.rb test/integration/system_settings_runtime_settings_test.rb test/integration/system_settings_agent_programs_test.rb test/integration/forked_agent_execution_test.rb app/models/runtime_setting.rb app/services/agent_programs/bootstrap_bundled_default_service.rb app/services/agent_programs/fork_service.rb app/controllers/system/settings/runtime_settings_controller.rb
git commit -m "fix: require a dedicated custom agent workspace root"
```

### Task 3: Batch 2A Planning Must Fail Explicitly On Stale Program/Deployment Binding

**Files:**
- Modify: `test/integration/run_draft_finalization_test.rb`
- Modify: `test/integration/conversation_messages_test.rb`
- Modify: `app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `app/models/run_draft.rb`

**Step 1: Write the failing tests**

Add one test where `conversation.agent_program.published_contract_fingerprint` no longer matches the only active deployment contract, and assert Cybros returns a structured validation error instead of bubbling `ActiveRecord::RecordInvalid`.

Add one request-level test that posts a message and receives `422` with the stale-selection message.

**Step 2: Run the tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/run_draft_finalization_test.rb test/integration/conversation_messages_test.rb`

Expected: FAIL because `RunDraft.create!` currently raises model validation failure instead of a planning-time stale-selection error.

**Step 3: Write the minimal implementation**

Move the stale-binding check into planning before `RunDraft.create!`:

- compare selected program fingerprint to the active deployment fingerprint/contract before draft creation
- raise `AgentCore::ValidationError` with a stable stale-selection code
- leave `RunDraft` model validation in place as a defense-in-depth invariant

**Step 4: Run the tests to verify they pass**

Run the same command from Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add test/integration/run_draft_finalization_test.rb test/integration/conversation_messages_test.rb app/services/run_drafts/conversation_turn_planning_service.rb app/models/run_draft.rb
git commit -m "fix: block stale programmable bindings during planning"
```

### Task 4: Batch 2B Parked Drafts Must Pin Their Own Config Schema

**Files:**
- Create: `db/migrate/20260310153000_add_agent_config_schema_fingerprint_to_run_drafts.rb`
- Modify: `db/schema.rb`
- Modify: `test/integration/run_draft_finalization_test.rb`
- Modify: `test/integration/run_draft_approval_resume_test.rb`
- Modify: `app/models/run_draft.rb`
- Modify: `app/services/run_drafts/conversation_turn_planning_service.rb`
- Modify: `app/services/run_drafts/finalize_service.rb`

**Step 1: Write the failing tests**

Add coverage that proves:

```ruby
test "approval-resumed run snapshots the draft's pinned config schema fingerprint" do
  draft = build_prepared_draft!(agent_program: original_program)
  conversation.update!(agent_program: alternate_program, agent_config_schema_fingerprint: alternate_program.config_schema_fingerprint)

  run = RunDrafts::ApprovalResumeService.resume!(draft: approve!(draft))

  assert_equal original_program.config_schema_fingerprint, run.agent_config_schema_fingerprint
end
```

Add a second test where staged agent-config mutations from the parked draft do not overwrite the live conversation schema pointer after the conversation selection changed.

**Step 2: Run the tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb`

Expected: FAIL because drafts do not currently store their own schema fingerprint.

**Step 3: Write the minimal implementation**

Add `agent_config_schema_fingerprint` to `run_drafts`, populate it from the selected program during planning, and use the draft-pinned value when finalizing `ConversationRun`. Do not rewrite `Conversation.agent_config_schema_fingerprint` during finalization unless the conversation is still bound to the same selected program.

**Step 4: Run the tests to verify they pass**

Run the same command from Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add db/migrate/20260310153000_add_agent_config_schema_fingerprint_to_run_drafts.rb db/schema.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb app/models/run_draft.rb app/services/run_drafts/conversation_turn_planning_service.rb app/services/run_drafts/finalize_service.rb
git commit -m "fix: pin parked drafts to their selected config schema"
```

### Task 5: Batch 3A Remove The Public Agent Program Management Surface

**Files:**
- Modify: `config/routes.rb`
- Delete: `app/controllers/agent_programs_controller.rb`
- Delete: `app/views/agent_programs/index.html.erb`
- Delete: `app/views/agent_programs/new.html.erb`
- Delete: `app/views/agent_programs/show.html.erb`
- Modify: `app/views/layouts/agent/_sidebar_primary_nav.html.erb`
- Modify: `test/integration/top_level_pages_smoke_test.rb`

**Step 1: Write the failing tests**

Add or update coverage so authenticated non-operator users cannot browse or create top-level `agent_programs`, and the standard agent sidebar no longer renders an `Agents` entry.

**Step 2: Run the tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/top_level_pages_smoke_test.rb`

Expected: FAIL because the public route and nav entry still exist.

**Step 3: Write the minimal implementation**

Remove the public `agent_programs` routes and views entirely. Keep all registration/fork/deployment management under `System Settings`, which already has owner/admin gating.

**Step 4: Run the tests to verify they pass**

Run the same command from Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add config/routes.rb app/views/layouts/agent/_sidebar_primary_nav.html.erb test/integration/top_level_pages_smoke_test.rb
git rm app/controllers/agent_programs_controller.rb app/views/agent_programs/index.html.erb app/views/agent_programs/new.html.erb app/views/agent_programs/show.html.erb
git commit -m "fix: keep agent program management in operator settings"
```

### Task 6: Batch 3B Bundled `default` Must Behave As A Singleton, And Managed-Local Registration Must Stay Reachable

**Files:**
- Modify: `test/integration/agent_programs_test.rb`
- Modify: `test/integration/system_settings_agent_programs_test.rb`
- Modify: `test/integration/agent_deployments_registration_test.rb`
- Modify: `app/services/agent_programs/creator.rb`
- Modify: `app/controllers/system/settings/agent_programs_controller.rb`
- Modify: `app/views/system/settings/agent_programs/index.html.erb`
- Modify: `app/views/system/settings/agent_deployments/_form.html.erb`

**Step 1: Write the failing tests**

Add one test proving that trying to “create” bundled key `default` a second time does not rename the official bundled program.

Add one UI/request test proving managed-local deployment registration works when `endpoint_url` is blank.

**Step 2: Run the tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb test/integration/agent_deployments_registration_test.rb`

Expected: FAIL because bundled creation currently upserts and overwrites `name`, and the HTML form still requires `endpoint_url`.

**Step 3: Write the minimal implementation**

Implement both repairs:

- `AgentPrograms::Creator.create_from_bundled_source!` must treat existing bundled key `default` as immutable bootstrap identity, not a renameable create target
- system settings UI should stop advertising “New agent” for the singleton bundled default path; prefer view/fork actions
- deployment registration form must allow blank `endpoint_url` and explain that blank means managed-local auto-allocation

**Step 4: Run the tests to verify they pass**

Run the same command from Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb test/integration/agent_deployments_registration_test.rb app/services/agent_programs/creator.rb app/controllers/system/settings/agent_programs_controller.rb app/views/system/settings/agent_programs/index.html.erb app/views/system/settings/agent_deployments/_form.html.erb
git commit -m "fix: preserve bundled default identity and managed-local registration"
```

### Task 7: Batch 4 Default Interactive Runtime Must Resolve From `AgentProgram`, Not `agent_profile`

**Files:**
- Modify: `test/integration/conversations_test.rb`
- Modify: `test/models/conversation_input_policy_resolver_test.rb`
- Modify: `test/lib/cybros/agent_runtime_resolver_test.rb`
- Modify: `test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb`
- Modify: `test/integration/conversation_agent_program_selection_test.rb`
- Modify: `app/controllers/conversations_controller.rb`
- Modify: `app/models/conversation/input_policy_resolver.rb`
- Modify: `lib/cybros/agent_runtime_resolver.rb`
- Modify: `app/models/agent_program.rb`

**Step 1: Write the failing tests**

Add coverage that proves:

- new conversations do not write `metadata["agent"]["agent_profile"] = "coding"`
- default model selection comes from the selected program manifest snapshot
- default input policy comes from the selected program manifest snapshot
- default runtime surface resolution for the top-level interactive path comes from the selected program contract snapshot rather than `agent_profile`

**Step 2: Run the tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/conversations_test.rb test/models/conversation_input_policy_resolver_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/integration/conversation_agent_program_selection_test.rb`

Expected: FAIL because the interactive path still seeds and resolves runtime behavior from metadata.

**Step 3: Write the minimal implementation**

Introduce a manifest-backed resolution path for top-level interactive conversations:

- `ConversationsController#create` should seed the selected `AgentProgram` only, not `agent_profile`
- add helper methods on `AgentProgram` for manifest-backed `model.prefer`, `input_policy`, and `runtime_surface`
- `Conversation::InputPolicyResolver` and `Cybros::AgentRuntimeResolver` should use the selected program for top-level interactive conversations
- keep legacy metadata parsing only as a temporary fallback for historical rows or subagent-specific carry-forward paths

**Step 4: Run the tests to verify they pass**

Run the same command from Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add test/integration/conversations_test.rb test/models/conversation_input_policy_resolver_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/agent_runtime_resolver_llm_provider_test.rb test/integration/conversation_agent_program_selection_test.rb app/controllers/conversations_controller.rb app/models/conversation/input_policy_resolver.rb lib/cybros/agent_runtime_resolver.rb app/models/agent_program.rb
git commit -m "fix: resolve interactive runtime authority from agent programs"
```

### Task 8: Batch 5 Delete Live Legacy Shims And Converge The Docs

**Files:**
- Create: `db/migrate/20260310170000_remove_legacy_agent_profile_shim_fields.rb`
- Modify: `db/schema.rb`
- Modify: `test/integration/agent_programs_test.rb`
- Modify: `test/services/agent_programs/bootstrap_bundled_default_service_test.rb`
- Modify: `app/services/agent_programs/bootstrap_bundled_default_service.rb`
- Modify: `app/services/agent_programs/creator.rb`
- Delete: `app/services/agent_programs/bundled_profiles.rb`
- Modify: `docs/agent_core/public_api.md`
- Modify: `docs/dag/subagent_patterns.md`
- Modify: `docs/agent_core/security.md`
- Modify: `docs/product/runtime_governance.md`

**Step 1: Write the failing tests**

Add or update coverage so:

- `create_from_profile!` and `BundledProfiles` are no longer callable
- bootstrap no longer carries the nil-program compatibility backfill branch outside one-time migration code
- docs no longer describe `agent_profile` metadata as the active programmable contract for the top-level path

**Step 2: Run the tests to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/agent_programs_test.rb test/services/agent_programs/bootstrap_bundled_default_service_test.rb`

Expected: FAIL because the legacy APIs and bootstrap shim still exist.

**Step 3: Write the minimal implementation**

Delete the live legacy surface:

- remove `create_from_profile!`
- remove `BundledProfiles`
- remove `profile_source` and `active_persona`
- remove runtime backfill logic that keeps `nil agent_program_id` as a living compatibility branch
- update docs so non-archive material matches the post-cut programmable-agent model

**Step 4: Run the tests to verify they pass**

Run the same command from Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add db/migrate/20260310170000_remove_legacy_agent_profile_shim_fields.rb db/schema.rb test/integration/agent_programs_test.rb test/services/agent_programs/bootstrap_bundled_default_service_test.rb app/services/agent_programs/bootstrap_bundled_default_service.rb app/services/agent_programs/creator.rb docs/agent_core/public_api.md docs/dag/subagent_patterns.md docs/agent_core/security.md docs/product/runtime_governance.md
git rm app/services/agent_programs/bundled_profiles.rb
git commit -m "fix: remove legacy programmable-agent compatibility shims"
```

### Task 9: Batch Verification, Reaudit, And Closeout

**Files:**
- Review only the changed files from the completed batches
- Modify: `docs/plans/2026-03-10-full-reaudit-baseline.md`

**Step 1: Run the batch-targeted suite after each batch**

Run only the tests listed in the completed batch.

Expected: PASS before proceeding.

**Step 2: Run a focused programmable-agent regression suite after Batch 5**

Run: `PARALLEL_WORKERS=1 bin/rails test test/integration/conversation_agent_program_selection_test.rb test/integration/run_draft_finalization_test.rb test/integration/run_draft_approval_resume_test.rb test/integration/agent_deployments_registration_test.rb test/integration/system_settings_agent_programs_test.rb test/lib/cybros/subagent/tools_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/models/conversation_input_policy_resolver_test.rb`

Expected: PASS

**Step 3: Update the audit doc**

Mark only the findings that were actually fixed as closed, with the exact commit references or verification commands.

**Step 4: Request code review before merge**

Use `requesting-code-review` on the final remediation diff. Apply validated feedback one item at a time, rerunning the narrowest relevant test after each change.
