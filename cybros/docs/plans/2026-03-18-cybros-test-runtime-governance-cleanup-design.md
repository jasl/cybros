# Cybros Test Runtime Governance Cleanup Design

## Status

Approved design notes for a destructive cleanup of the runtime-governance and agent-runtime-fixture truth sources under `cybros/test/`.

This design intentionally reuses the exact cleanup method established in the 2026-03-17 main-app cleanup:

- establish an explicit truth-source baseline before editing
- record findings in a cleanup ledger
- classify every finding as `delete`, `archive`, `keep`, or `Rails-shaped simplify`
- work highest-priority residue first
- re-scan after every round
- finish with a mandatory retrospective re-audit

Compatibility is not a goal. The priority is to stop tests from teaching developers an obsolete `program` / `execution_target` worldview when the live model is `Agent`-owned.

## Goal

Clean the selected runtime-governance test cluster so shared test truth sources, local fixture helpers, and high-visibility runtime assertions reflect the current `Agent`-centric model.

The cleanup should:

- remove stale test helper narratives that still call an `Agent` a `program`
- remove synthetic `execution_target` fixture scaffolding where the live model is agent-owned capacity
- simplify test setup so runtime-governance and recognized-deployment tests build the world through `Agent` and runtime bindings
- keep explicit negative coverage that proves removed columns and removed runtime nouns stay gone

## Scope

Primary target range:

- `cybros/test/test_helper.rb`
- `cybros/test/models/agent_test.rb`
- `cybros/test/models/recognized_deployment_test.rb`
- `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb`
- `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb`
- `cybros/test/integration/execution_capacity_enforcement_test.rb`
- `cybros/test/integration/runtime_governance_observability_test.rb`
- `cybros/test/integration/system_settings_runtime_governance_test.rb`
- the new cleanup docs for this pass under `cybros/docs/plans/`

Adjacent files outside this range may be inspected during re-audit, but they are not automatic edit targets unless they block conceptual cleanliness inside the scoped cluster.

## Non-Goals

- no broad cleanup of the entire `cybros/test/` tree in this pass
- no product/runtime behavior changes outside what is required to align tests with the current model
- no semantic `superseded` state for old docs
- no forced deletion of shared helper surfaces that still have active consumers outside this scope

## Success Criteria

The cleanup is successful when all of the following are true:

- the selected test cluster no longer uses local helper names that present `Agent` records as `program` fixtures
- the selected cluster no longer depends on local `create_execution_target!` scaffolding to explain agent-owned capacity behavior
- shared or local fixture hashes no longer expose `program` / `target` as current runtime anchors when those values are just legacy naming wrappers around `Agent`
- explicit negative assertions about removed columns or removed runtime nouns remain only as rejection/regression coverage
- the work runs in four cleanup rounds after the baseline round, followed by a mandatory retrospective re-audit
- every cleanup round rescans the priority band before the next round begins
- the ledger records reusable strategy lessons for future test-tree cleanup

## Cleanup Principles

1. Misleading shared test truth sources matter more than local variable style.
2. Tests that teach obsolete architecture matter more than tests that are merely verbose.
3. Delete fake infrastructure nouns before polishing naming.
4. Keep explicit negative coverage only when it proves removed truth really stays removed.
5. Re-scan every round instead of trusting earlier inventories.

## Classification Rules

Every finding must be assigned one action:

### Delete

Use `delete` for stale local helpers, fixture hash keys, or setup branches that no longer belong to the agent-owned runtime model.

### Archive

Use `archive` only for docs with historical value. This pass does not expect archive-heavy work, but the option remains available if active cleanup docs become misleading.

### Rails-Shaped Simplify

Use `Rails-shaped simplify` when the issue is concept sprawl rather than a single dead branch, especially when tests can directly build `Agent` state instead of manufacturing fake intermediate profiles.

### Keep

Use `keep` only when a surface is still live, or when deleting it inside this scope would leave broader active consumers broken. Every keep decision must include a reason.

## Priority Model

- `P0`: shared truth sources and anchor tests that directly teach the wrong model
- `P1`: runtime-governance service/integration tests that still build capacity through legacy naming or fake target scaffolding
- `P2`: observability and system-test simplification within the scoped cluster
- `P3`: lower-risk adjacent residue intentionally deferred outside this scoped pass

Lower-priority work must not begin until the current priority band is rescanned and either clean or explicitly deferred.

## Truth Source Policy

At the start of the work, the cleanup must maintain an explicit truth-source list answering:

- which process docs govern this cleanup method
- which code files define the current runtime-governance truth
- which shared test helpers are active truth sources for the scoped cluster
- which old nouns are removal targets versus explicit negative coverage to keep

## Execution Strategy

This cleanup runs in six passes:

### Round 1: Inventory And Truth-Source Baseline

- create the new design, implementation plan, and ledger
- define active truth sources
- classify scoped findings by priority and action
- record keep/defer decisions before any edits

### Round 2: P0 Shared Test Truth Cleanup

- clean the anchor model tests and shared helper narratives that still present `Agent` fixtures as `program`
- remove scoped `execution_target` fixture helpers where agent-owned capacity already tells the truth
- verify the anchor suites and rescan

### Round 3: P1 Runtime Governance Service/Integration Cleanup

- clean runtime-governance service tests and execution-capacity integration tests
- rename stale local helpers and hash keys that still preserve the old worldview
- verify the focused cluster and rescan

### Round 4: P2 Observability Simplification

- clean runtime-governance observability tests
- collapse local helper naming so governed subjects are created directly as agents and recognized deployments
- verify and rescan

### Round 5: P3 System Surface Cleanup

- clean the scoped system/integration surface
- remove residual `execution_target` naming in the selected system coverage where agent-owned capacity is already the live boundary
- verify and rescan

### Round 6: Retrospective Re-Audit

- rerun the baseline discovery method on the scoped cluster
- verify that remaining residue is intentional and logged
- run fresh verification evidence, including a broader suite when feasible

## Round Workflow

Each round follows the same loop:

1. re-scan with the baseline query set plus round-specific probes
2. update the ledger before editing
3. edit only the highest-priority explicit batch
4. run targeted verification
5. re-scan before closing the round
6. record what remains and why

## Verification Gates

### Batch Gate

Before a batch is done:

- targeted old nouns should be absent from the selected files, or intentionally preserved only as negative coverage
- touched tests must pass targeted verification
- the ledger must be updated with the batch closeout

### Round Gate

Before moving to the next round:

- the current priority band must be rescanned
- unresolved residue must be explicitly deferred with a reason
- lower-priority work must not start while higher-priority active truth is still misleading

### Final Gate

Before closing the cleanup:

- run the retrospective re-audit
- provide fresh verification evidence
- state clearly whether the broader/full suite passed
- log remaining defer items instead of silently dropping them
