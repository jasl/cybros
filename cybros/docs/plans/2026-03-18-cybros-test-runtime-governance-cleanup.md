# Cybros Test Runtime Governance Cleanup Implementation Plan

> **For Codex:** Reuse the 2026-03-17 cleanup method exactly: establish truth sources first, work by priority band, re-scan every round, and finish with a retrospective re-audit.

**Goal:** Remove misleading `program` / `execution_target` truth sources from the selected runtime-governance and agent-runtime-fixture tests under `cybros/test/`.

**Architecture:** Use a dedicated cleanup ledger and truth-source baseline, then run four verified cleanup rounds:

1. P0 anchor truth cleanup
2. P1 runtime-governance service/integration cleanup
3. P2 observability simplification
4. P3 system-surface cleanup

Finish with a mandatory retrospective re-audit and fresh verification evidence.

**Execution Root:** `/Users/jasl/Workspaces/Cybros/cybros`

**Execution Preconditions:**

- run every command from `/Users/jasl/Workspaces/Cybros/cybros`
- keep PostgreSQL available before any `bin/rails test` command
- do not widen a batch just because `rg` finds more hits; record leftovers in the ledger and continue in explicit rounds
- destructive edits are allowed; do not preserve compatibility layers

---

### Task 1: Create The Design, Plan, And Cleanup Ledger

**Files:**

- Create: `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup-design.md`
- Create: `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup.md`
- Create: `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup-ledger.md`
- Reference: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-design.md`
- Reference: `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`

**Step 1:** Create the ledger skeleton with:

- Active truth sources
- Target scope
- P0/P1/P2/P3 findings
- Delete/archive/keep/simplify decisions
- Round closeout notes
- Reusable strategy lessons

**Step 2:** Run the scoped baseline discovery searches:

```bash
rg -n "create_program!|create_execution_target!|execution_profile:|\\bprogram\\b|\\btarget\\b|execution_target|default_execution_target" \
  cybros/test/test_helper.rb \
  cybros/test/models/agent_test.rb \
  cybros/test/models/recognized_deployment_test.rb \
  cybros/test/services/runtime_governance \
  cybros/test/integration/execution_capacity_enforcement_test.rb \
  cybros/test/integration/runtime_governance_observability_test.rb \
  cybros/test/integration/system_settings_runtime_governance_test.rb
```

**Step 3:** Record the active truth sources and first candidate batches before editing.

**Step 4:** Verify the ledger is concrete and file-backed.

### Task 2: Round 2 P0 Cleanup For Shared Test Truth Sources

**Files:**

- `cybros/test/models/agent_test.rb`
- `cybros/test/models/recognized_deployment_test.rb`
- `cybros/test/test_helper.rb` only if needed for scoped helper tightening
- `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup-ledger.md`

**Step 1:** Re-scan the P0 files.

**Step 2:** Replace stale local helper names and synthetic target setup in the anchor tests so they model agent-owned capacity directly.

**Step 3:** Keep negative coverage that proves removed runtime nouns stay rejected.

**Step 4:** Run targeted verification:

```bash
bin/rails test \
  cybros/test/models/agent_test.rb \
  cybros/test/models/recognized_deployment_test.rb
```

**Step 5:** Re-scan the P0 files and update the ledger closeout.

### Task 3: Round 3 P1 Cleanup For Runtime Governance Services And Execution-Capacity Integration

**Files:**

- `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb`
- `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb`
- `cybros/test/integration/execution_capacity_enforcement_test.rb`
- `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup-ledger.md`

**Step 1:** Re-scan the selected files for stale helper names and fixture hash keys.

**Step 2:** Rename local helpers and runtime hashes so they expose `agent`, `deployment`, and `recognized_deployment` as the live anchors.

**Step 3:** Remove any scoped fake target scaffolding that still explains capacity through the obsolete model.

**Step 4:** Run targeted verification:

```bash
bin/rails test \
  cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb \
  cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb \
  cybros/test/integration/execution_capacity_enforcement_test.rb
```

**Step 5:** Re-scan and update the ledger closeout.

### Task 4: Round 4 P2 Observability Simplification

**Files:**

- `cybros/test/integration/runtime_governance_observability_test.rb`
- `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup-ledger.md`

**Step 1:** Re-scan the file for `program`-centric helpers and stale subject naming.

**Step 2:** Collapse local helper naming so governed subjects are built directly from agents and recognized deployments.

**Step 3:** Preserve explicit negative coverage only when it still proves removed subject types stay out of the active model.

**Step 4:** Run targeted verification:

```bash
bin/rails test cybros/test/integration/runtime_governance_observability_test.rb
```

**Step 5:** Re-scan and update the ledger closeout.

### Task 5: Round 5 P3 System Surface Cleanup

**Files:**

- `cybros/test/integration/system_settings_runtime_governance_test.rb`
- `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup-ledger.md`

**Step 1:** Re-scan the file for local `execution_target` helper narratives.

**Step 2:** Replace those helpers with direct agent-capacity setup and current naming.

**Step 3:** Run targeted verification:

```bash
bin/rails test cybros/test/integration/system_settings_runtime_governance_test.rb
```

**Step 4:** Re-scan and update the ledger closeout.

### Task 6: Round 6 Retrospective Re-Audit And Fresh Verification

**Files:**

- `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup-ledger.md`

**Step 1:** Re-run the baseline discovery query across the scoped cluster.

**Step 2:** Run targeted aggregate verification for every touched scoped file.

**Step 3:** Run a broader verification command:

```bash
bin/rails test
```

If the broader suite fails because a simplification leaked outside the scoped pass, narrow or revert the offending simplification and record that lesson in the ledger before declaring success.

**Step 4:** Record the final re-audit status, remaining keeps/defer items, and reusable strategy lessons.
