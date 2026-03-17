# Cybros Main App Cleanup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove misleading active truth sources from the main `cybros/` Rails app through a four-round cleanup plus retrospective re-audit, while recording a reusable cleanup strategy.

**Architecture:** Start with an explicit cleanup ledger and truth-source baseline, then execute P0 live-path cleanup, P1 test/helper cleanup, and P2 Rails-shaped simplification in separate verified rounds. Couple code, tests, and active docs whenever a concept is removed; archive or delete obsolete docs instead of marking them superseded; finish with a retrospective re-audit that reruns the original discovery method.

**Tech Stack:** Ruby 4.0.1, Rails 8.2.0.alpha, Minitest, Markdown docs, ripgrep, git

---

### Task 1: Create The Cleanup Ledger And Truth-Source Baseline

**Files:**
- Create: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`
- Reference: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-design.md`
- Reference: `cybros/docs/README.md`

**Step 1: Create the ledger skeleton**

Create `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md` with these sections:

- Active truth sources
- P0 live-path findings
- P1 test/helper findings
- P2 Rails-shaped simplify findings
- Archive candidates
- Delete candidates
- Keep-with-reason candidates
- Round closeout notes
- Reusable strategy notes

**Step 2: Run the baseline discovery searches**

Run:

```bash
rg -n "legacy|compat|shim|fallback|agent_program|execution_target|ExecutionTarget|ExecutionLocation|AgentDeployment|logical_workspace|agent_program_key" cybros/app cybros/lib cybros/config cybros/test cybros/docs --glob '!cybros/docs/archive/**' --glob '!cybros/app/assets/builds/**'
```

Expected: hits across live code, active docs, and tests that can be sorted into P0/P1/P2.

**Step 3: Record the initial truth sources and candidate lists**

Populate the ledger with:

- the active docs that still define current behavior
- the active docs that should be archived or deleted
- the current P0/P1/P2 candidate clusters
- the first dependency notes between clusters

**Step 4: Verify the ledger is actionable**

Run:

```bash
sed -n '1,240p' cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
```

Expected: the ledger contains concrete file-backed findings, not placeholders.

**Step 5: Commit**

```bash
git add cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
git commit -m "docs: add cybros main app cleanup ledger"
```

### Task 2: Archive Or Delete The Obvious Misleading Active Runtime Docs

**Files:**
- Modify or move: `cybros/docs/plans/2026-03-08-runtime-governance-design.md`
- Modify or move: `cybros/docs/plans/2026-03-08-runtime-governance.md`
- Modify or move: `cybros/docs/plans/2026-03-09-execution-target-discovery-design.md`
- Modify or move: `cybros/docs/plans/2026-03-09-runtime-governance-operator-surfaces.md`
- Modify: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`
- Optional archive destination: `cybros/docs/archive/plans/2026-03/`

**Step 1: Re-read the candidate docs before moving them**

Run:

```bash
sed -n '1,220p' cybros/docs/plans/2026-03-08-runtime-governance-design.md
sed -n '1,220p' cybros/docs/plans/2026-03-08-runtime-governance.md
sed -n '1,220p' cybros/docs/plans/2026-03-09-execution-target-discovery-design.md
sed -n '1,220p' cybros/docs/plans/2026-03-09-runtime-governance-operator-surfaces.md
```

Expected: these docs still describe `ExecutionLocation`, `Workspace`, and `ExecutionTarget` as live anchors.

**Step 2: Decide archive vs delete in the ledger**

Update the ledger so each file is explicitly marked `archive` or `delete`. Do not use a `superseded` state.

**Step 3: Perform the move or deletion**

- If a doc still has historical value, move it under `cybros/docs/archive/plans/2026-03/`.
- If it is only misleading noise, delete it.

**Step 4: Verify the active plans tree no longer treats execution targets as current**

Run:

```bash
rg -n "ExecutionTarget|ExecutionLocation|AgentDeployment" cybros/docs/plans --glob '!cybros/docs/archive/**'
```

Expected: only still-approved current docs remain, and the moved/deleted files are gone from the active plans tree.

**Step 5: Commit**

```bash
git add cybros/docs/plans cybros/docs/archive/plans/2026-03
git commit -m "docs: archive obsolete runtime planning docs"
```

### Task 3: Remove `agent_program_key` Fallback From Live Code

**Files:**
- Modify: `cybros/app/services/agents/creator.rb`
- Modify: `cybros/app/services/agent_rpc/session_authorizer.rb`
- Modify: `cybros/test/services/agents/creator_test.rb`
- Modify: `cybros/test/integration/agent_rpc_session_auth_test.rb`
- Modify: `cybros/test/services/agents/bootstrap_bundled_default_service_test.rb`
- Modify: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`

**Step 1: Write or update the failing tests**

Update the tests so bundled manifests and runtime identity payloads require `agent_key` and no longer accept `agent_program_key`.

At minimum, cover:

- bundled source creation in `cybros/test/services/agents/creator_test.rb`
- callback session auth / identity resolution in `cybros/test/integration/agent_rpc_session_auth_test.rb`
- bundled default bootstrap expectations in `cybros/test/services/agents/bootstrap_bundled_default_service_test.rb`

**Step 2: Run the targeted tests to confirm the fallback is still live**

Run:

```bash
bin/rails test \
  cybros/test/services/agents/creator_test.rb \
  cybros/test/integration/agent_rpc_session_auth_test.rb \
  cybros/test/services/agents/bootstrap_bundled_default_service_test.rb
```

Expected: FAIL because the implementation still falls back to `agent_program_key`.

**Step 3: Remove the fallback**

- delete `legacy_manifest_agent_key` from `cybros/app/services/agents/creator.rb`
- delete `legacy_manifest_agent_key` from `cybros/app/services/agent_rpc/session_authorizer.rb`
- require `agent_key` at both call sites

**Step 4: Re-run the targeted tests**

Run the same command as Step 2.

Expected: PASS.

**Step 5: Update the ledger**

Record that the live fallback path is removed and any remaining `agent_program_key` uses are now test/data cleanup only.

**Step 6: Commit**

```bash
git add cybros/app/services/agents/creator.rb cybros/app/services/agent_rpc/session_authorizer.rb cybros/test/services/agents/creator_test.rb cybros/test/integration/agent_rpc_session_auth_test.rb cybros/test/services/agents/bootstrap_bundled_default_service_test.rb cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
git commit -m "refactor: remove legacy manifest key fallback"
```

### Task 4: Normalize Manifest Fixtures From `agent_program_key` To `agent_key`

**Files:**
- Modify: every file returned by the search in Step 1
- Start with:
  - `cybros/test/lib/test_support/bundled_claw_runtime_server_test.rb`
  - `cybros/test/lib/cybros/programmable_agent_fixture_test.rb`
  - `cybros/test/integration/agent_runtime_binding_cutover_test.rb`
  - `cybros/test/integration/conversations_test.rb`
  - `cybros/test/integration/programmable_agent_execution_test.rb`
  - `cybros/test/integration/agent_rpc_runtime_state_cutover_test.rb`
  - `cybros/test/models/run_draft_test.rb`
  - `cybros/test/models/conversation_run_test.rb`
  - `cybros/test/services/agent_rpc/lifecycle_caller_test.rb`
  - `cybros/test/scenarios/dag/programmable_agent_step_status_placeholder_test.rb`
- Modify: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`

**Step 1: Enumerate the remaining fixture hits**

Run:

```bash
rg -n "agent_program_key" cybros/test cybros/app
```

Expected: a repo-wide list of fixture payloads and assertions that still use the old key.

**Step 2: Update the failing assertions and fixture payloads**

Replace `agent_program_key` with `agent_key` in the files returned by Step 1.

For runtime-identity tests, make sure both fixture payloads and assertions move together.

**Step 3: Run the focused test set**

Run:

```bash
bin/rails test \
  cybros/test/lib/test_support/bundled_claw_runtime_server_test.rb \
  cybros/test/lib/cybros/programmable_agent_fixture_test.rb \
  cybros/test/models/run_draft_test.rb \
  cybros/test/models/conversation_run_test.rb \
  cybros/test/integration/agent_runtime_binding_cutover_test.rb \
  cybros/test/integration/agent_rpc_runtime_state_cutover_test.rb \
  cybros/test/integration/programmable_agent_execution_test.rb
```

Expected: PASS.

**Step 4: Verify no live `agent_program_key` residue remains outside approved historical locations**

Run:

```bash
rg -n "agent_program_key" cybros/app cybros/lib cybros/config cybros/test cybros/docs --glob '!cybros/docs/archive/**'
```

Expected: no hits, or only findings explicitly recorded for a later round in the ledger.

**Step 5: Commit**

```bash
git add cybros/test cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
git commit -m "test: rename manifest fixtures to agent key"
```

### Task 5: Simplify `test/test_helper.rb` Conversation And Runtime Builder APIs

**Files:**
- Modify: `cybros/test/test_helper.rb`
- Modify: every file returned by the Step 1 search
- Start with:
  - `cybros/test/models/recognized_deployment_test.rb`
  - `cybros/test/models/conversation_run_test.rb`
  - `cybros/test/models/run_draft_test.rb`
  - `cybros/test/models/agent_test.rb`
  - `cybros/test/services/agent_rpc/lifecycle_caller_test.rb`
  - `cybros/test/integration/agent_rpc_lost_reply_recovery_test.rb`
  - `cybros/test/integration/execution_capacity_enforcement_test.rb`
  - `cybros/test/integration/agent_runtime_binding_cutover_test.rb`
  - `cybros/test/integration/run_draft_finalization_test.rb`
  - `cybros/test/integration/run_draft_approval_resume_test.rb`
- Modify: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`

**Step 1: Write a failing helper contract test**

Add or update tests so helper call sites no longer pass:

- `agent_program:` to `create_conversation!`
- `default_execution_target:` to `create_conversation!`
- `program:` / `execution_target:` to runtime materializers when only the `Agent` should be the public fixture input

If there is no dedicated helper test file, add the assertions to `cybros/test/models/agent_test.rb` or a nearby helper-focused test file.

**Step 2: Run a focused test set and confirm the old helper contract is still in use**

Run:

```bash
bin/rails test \
  cybros/test/models/agent_test.rb \
  cybros/test/models/run_draft_test.rb \
  cybros/test/models/conversation_run_test.rb \
  cybros/test/models/recognized_deployment_test.rb \
  cybros/test/services/agent_rpc/lifecycle_caller_test.rb
```

Expected: FAIL or require updates because the helper API still accepts the old nouns.

**Step 3: Remove the obsolete helper parameters**

In `cybros/test/test_helper.rb`:

- remove `default_execution_target` and `agent_program` from `create_conversation!`
- replace `program:` naming with `agent:` naming in runtime materializer helpers where that aligns with the real model
- delete helper behavior that only exists to bridge old target/program concepts into current tests

**Step 4: Update the touched call sites**

Update the files returned by Step 1 so they use the simplified helper API.

**Step 5: Re-run the focused tests**

Run the same command from Step 2, then add any immediately affected integration files from the Step 1 search until the helper contract is stable.

Expected: PASS.

**Step 6: Commit**

```bash
git add cybros/test/test_helper.rb cybros/test/models cybros/test/services cybros/test/integration cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
git commit -m "test: remove legacy conversation fixture helpers"
```

### Task 6: Remove `ExecutionTarget`-Centric Test Profiles From Runtime Governance And Automation Tests

**Files:**
- Modify: `cybros/test/test_helper.rb`
- Modify: `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb`
- Modify: `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb`
- Modify: `cybros/test/integration/execution_capacity_enforcement_test.rb`
- Modify: `cybros/test/integration/runtime_governance_observability_test.rb`
- Modify: `cybros/test/services/automations/dispatch_test.rb`
- Modify: `cybros/test/jobs/automations/dispatch_due_job_test.rb`
- Modify: `cybros/test/jobs/automations/execute_conversation_job_test.rb`
- Modify: `cybros/test/models/automation_test.rb`
- Modify: `cybros/test/integration/automation_failure_recovery_test.rb`
- Modify: `cybros/test/integration/automation_execution_conversation_test.rb`
- Modify: `cybros/test/integration/automation_execution_run_draft_flow_test.rb`
- Modify: `cybros/test/integration/automation_manual_approval_test.rb`
- Modify: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`

**Step 1: Re-audit the target-centric test setup**

Run:

```bash
rg -n "create_execution_target!|execution_target:|default_execution_target" cybros/test/services/runtime_governance cybros/test/integration cybros/test/jobs cybros/test/models/automation_test.rb
```

Expected: the remaining execution-target-centric tests cluster in runtime governance and automation flows.

**Step 2: Write or update the failing tests**

Update the selected test files so they describe capacity and automation behavior through `Agent` runtime attributes, not through synthetic execution-target fixtures.

**Step 3: Remove the obsolete execution-target profile helpers**

In `cybros/test/test_helper.rb`:

- delete or collapse `create_execution_location_profile!`
- delete or collapse `create_workspace_profile!`
- delete or collapse `create_execution_profile!`
- remove any remaining helper branches that only feed `execution_target` state into `Agent`

**Step 4: Update the selected tests**

Move the selected runtime governance and automation tests to agent-centric setup.

**Step 5: Run the selected tests**

Run:

```bash
bin/rails test \
  cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb \
  cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb \
  cybros/test/integration/execution_capacity_enforcement_test.rb \
  cybros/test/integration/runtime_governance_observability_test.rb \
  cybros/test/services/automations/dispatch_test.rb \
  cybros/test/jobs/automations/dispatch_due_job_test.rb \
  cybros/test/jobs/automations/execute_conversation_job_test.rb \
  cybros/test/models/automation_test.rb \
  cybros/test/integration/automation_failure_recovery_test.rb \
  cybros/test/integration/automation_execution_conversation_test.rb \
  cybros/test/integration/automation_execution_run_draft_flow_test.rb \
  cybros/test/integration/automation_manual_approval_test.rb
```

Expected: PASS.

**Step 6: Commit**

```bash
git add cybros/test/test_helper.rb cybros/test/services/runtime_governance cybros/test/services/automations cybros/test/jobs/automations cybros/test/models/automation_test.rb cybros/test/integration cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
git commit -m "test: remove execution target fixture scaffolding"
```

### Task 7: Re-Audit Active Docs And Archive Or Delete Remaining Misleading Files

**Files:**
- Modify or move: every active doc file recorded in the ledger as `archive` or `delete`
- Start with any remaining hits under:
  - `cybros/docs/plans/`
  - `cybros/docs/agent_core/`
  - `cybros/docs/dag/`
  - `cybros/docs/README.md`
- Modify: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`

**Step 1: Run the active-doc truth-source search**

Run:

```bash
rg -n "ExecutionTarget|ExecutionLocation|AgentDeployment|agent_program|default_execution_target|logical_workspace" cybros/docs --glob '!cybros/docs/archive/**' --glob '!cybros/docs/product.old/**' --glob '!cybros/docs/execution.old/**'
```

Expected: a smaller active-doc hit list than the initial inventory.

**Step 2: Resolve each remaining active-doc hit**

For each hit recorded in the ledger:

- archive the doc if it is historical
- delete it if it is only misleading noise
- rewrite it only if it is an active truth source that must stay active

Do not leave the file in place with a `superseded` note.

**Step 3: Re-run the doc search**

Run the same command from Step 1.

Expected: only intentional current-model references remain in active docs.

**Step 4: Commit**

```bash
git add cybros/docs cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
git commit -m "docs: clear remaining misleading active references"
```

### Task 8: Land One High-Confidence Rails-Shaped Simplification After P0/P1 Are Clean

**Files:**
- Re-audit first, then modify the best candidate from the ledger
- Preferred starting candidate:
  - `cybros/app/models/conversation.rb`
  - `cybros/app/services/conversations/workspace_initializer.rb`
  - `cybros/test/models/conversation_program_selection_test.rb`
  - `cybros/test/services/agents/workspace_initializer_test.rb`
- Modify: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`

**Step 1: Verify P0 and P1 are closed before simplifying**

Run:

```bash
rg -n "agent_program_key|agent_program:|default_execution_target|execution_target:" cybros/app cybros/lib cybros/test cybros/docs --glob '!cybros/docs/archive/**'
```

Expected: only intentionally logged residue remains.

**Step 2: Re-read the workspace ownership files**

Run:

```bash
sed -n '270,330p' cybros/app/models/conversation.rb
sed -n '1,240p' cybros/app/services/conversations/workspace_initializer.rb
sed -n '1,220p' cybros/test/models/conversation_program_selection_test.rb
sed -n '1,220p' cybros/test/services/agents/workspace_initializer_test.rb
```

Expected: a clear decision on whether `Conversations::WorkspaceInitializer` should stay as a thin wrapper, be collapsed, or be narrowed.

**Step 3: Write the failing test for the simplification**

Add or update tests around the chosen candidate so the simplification is behavior-preserving.

**Step 4: Implement the simplification**

Make only the smallest change needed for the chosen high-confidence hotspot. Do not open a second simplify front in the same task.

**Step 5: Run the targeted tests**

Run:

```bash
bin/rails test \
  cybros/test/models/conversation_program_selection_test.rb \
  cybros/test/services/agents/workspace_initializer_test.rb
```

Expected: PASS.

**Step 6: Commit**

```bash
git add cybros/app/models/conversation.rb cybros/app/services/conversations/workspace_initializer.rb cybros/test/models/conversation_program_selection_test.rb cybros/test/services/agents/workspace_initializer_test.rb cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
git commit -m "refactor: simplify workspace ownership boundary"
```

### Task 9: Review Tracked Repository Clutter Inside `cybros/`

**Files:**
- Review and act on files recorded in the ledger under:
  - `cybros/docs/reports/`
  - `cybros/docs/product.old/`
  - `cybros/docs/execution.old/`
  - `cybros/tmp/`
- Modify: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`

**Step 1: Enumerate tracked clutter candidates**

Run:

```bash
git ls-files cybros/docs/reports cybros/docs/product.old cybros/docs/execution.old cybros/tmp
```

Expected: a concrete list of tracked historical files and temp artifacts.

**Step 2: Resolve only the misleading or clearly non-valuable tracked items**

For each candidate:

- archive if it has historical value and still needs to exist
- delete if it is just clutter
- keep only with a written reason in the ledger

**Step 3: Verify no accidental active references point at removed files**

Run:

```bash
rg -n "docs/reports|product\\.old|execution\\.old|cybros/tmp" cybros/docs cybros/README.md cybros/AGENTS.md
```

Expected: no broken active references.

**Step 4: Commit**

```bash
git add cybros/docs cybros/tmp cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
git commit -m "chore: clear tracked cybros clutter"
```

### Task 10: Run The Retrospective Re-Audit And Finalize The Reusable Strategy

**Files:**
- Modify: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`
- Modify if needed: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-design.md`

**Step 1: Re-run the original discovery queries**

Run:

```bash
rg -n "legacy|compat|shim|fallback|agent_program|execution_target|ExecutionTarget|ExecutionLocation|AgentDeployment|logical_workspace|agent_program_key" cybros/app cybros/lib cybros/config cybros/test cybros/docs --glob '!cybros/docs/archive/**' --glob '!cybros/app/assets/builds/**'
```

Expected: only intentional remaining hits, each with a written reason.

**Step 2: Record the final round-closeout notes**

Update the ledger with:

- what was removed
- what was archived
- what was intentionally kept
- what reusable strategy lessons changed during execution

**Step 3: Run the final targeted verification set**

Run the targeted file-level commands accumulated in earlier tasks, then run:

```bash
PARALLEL_WORKERS=1 bin/rails test
```

Expected: PASS.

If the full suite is too slow to use on every inner loop, it is still required here before closeout.

**Step 4: Verify the strategy is explicitly reusable**

Read:

```bash
sed -n '1,260p' cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-design.md
sed -n '1,260p' cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md
```

Expected: a future engineer can reuse the scan categories, classification rules, priority model, verification gates, and re-audit method without guessing.

**Step 5: Commit**

```bash
git add cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-design.md
git commit -m "docs: finalize cybros cleanup re-audit notes"
```
