# Cybros Main App Cleanup Design

## Status

Approved design notes for a repository-level cleanup of the main `cybros/` Rails application.

This design is intentionally destructive. Compatibility layers are not a goal. The priority is to remove misleading or obsolete truth sources so future development does not keep inheriting stale concepts.

## Goal

Clean up the main `cybros/` Rails app so that active code, active tests, and active documentation reflect the current product/runtime model rather than a mixture of old and new concepts.

The cleanup should:

- remove dead code, obsolete branches, and compatibility surfaces
- reduce concept drift across `app/`, `lib/`, `test/`, and active docs
- simplify the codebase where a more Rails-shaped boundary would reduce cognitive overhead
- explicitly avoid leaving half-removed concepts behind

## Scope

This cleanup targets only the main `cybros/` Rails app subtree.

Primary targets:

- active code under `app/`, `lib/`, `config/`
- active test/support code under `test/`
- active docs under `docs/`
- repository-level clutter within `cybros/` when it materially misleads development

Historical material is not the main battlefield, but it is still in scope when it remains misleading. In particular:

- old design/product docs should be archived or deleted
- historical reports or tracked temp artifacts should be reviewed when they still pose as live guidance

## Non-Goals

- no cleanup of `nexus/` or `mothership/`
- no attempt to preserve compatibility with abandoned runtime models or nouns
- no broad feature development disguised as cleanup
- no history-preserving `superseded` state for old design docs; obsolete docs are archived or deleted
- no requirement to eliminate every historical artifact if it is already clearly archived and no longer misleading

## Why This Exists

The immediate reason for this work is that earlier cleanup passes still left misleading content behind. That created false signals for later development.

This design therefore optimizes for repeated discovery and re-audit rather than for a single heroic pass.

## Success Criteria

The cleanup is successful when all of the following are true:

- active code paths no longer expose obsolete runtime nouns, compatibility surfaces, or dead branches that are no longer part of the real model
- active tests, fixture builders, and helpers no longer keep old concepts alive after production cutover
- active docs have a small, explicit set of current truth sources
- outdated docs are archived or deleted rather than left in an ambiguous half-live state
- the work is executed in at least four cleanup rounds, followed by one mandatory retrospective re-audit round
- each round verifies that the targeted priority band is actually clean before lower-priority work begins
- the strategy itself is written down so later cleanup efforts can reuse the same method

## Cleanup Principles

The cleanup should be governed by these principles:

1. Misleading truth sources matter more than code style.
2. Live-path leftovers matter more than historical ugliness.
3. Test pollution matters more than cosmetic cleanup.
4. Delete or archive old concepts; do not preserve them as half-live references.
5. Fix high-priority residue first, verify it is clean, then move to lower-priority work.
6. Every round must rescan the repository instead of trusting the previous inventory.

## Classification Rules

Every finding must be classified as one of four actions:

### Delete

Use `delete` when a concept or file is still present in the active tree but no longer belongs to the current model.

Typical cases:

- dead branches
- compatibility shims
- obsolete runtime nouns
- stale helper APIs
- active docs that present abandoned models as current

### Archive

Use `archive` only for historical material that still has reference value but should not remain in active paths.

Typical cases:

- old design docs
- old product docs
- obsolete reports that still explain historical decisions

Archive is a documentation move, not a semantic state. Old docs should not be marked as `superseded`; they should either move into an archival location or be removed.

### Rails-Shaped Simplify

Use `Rails-shaped simplify` when the issue is not simply dead code but concept sprawl, misplaced responsibilities, or needless indirection.

Typical cases:

- app/lib boundary drift
- repeated service-layer orchestration that could be collapsed
- naming that fights Rails conventions
- duplicated ownership of the same concern across model/service/helper/test helper layers

### Keep

Use `keep` only when the item is still a live dependency or when the current round lacks a safe, coherent replacement.

Items marked `keep` should remain in the ledger with a reason, not disappear from consideration.

## Priority Model

All findings should also carry a priority:

- `P0`: misleading active code and active docs
- `P1`: misleading test helpers, fixtures, scenarios, and verification paths
- `P2`: Rails-shaped simplification, naming cleanup, and responsibility collapse
- `P3`: lower-risk repository slimming and residual clutter

The cleanup must not move into a lower-priority band until the current band has been cleaned and re-verified.

## Truth Source Policy

At the start of the work, the cleanup should establish an explicit truth-source list for active development.

That list should answer:

- which docs describe the current model
- which docs are historical only
- which code areas own the current runtime model
- which old nouns are considered removal targets

This truth-source list becomes the anchor for later rounds and for the retrospective re-audit.

## Execution Strategy

The work should run in five passes: four cleanup rounds and one mandatory retrospective re-audit round.

### Round 1: Inventory And Truth-Source Baseline

Purpose:

- scan the repository and build a cleanup ledger
- define the active truth sources
- identify delete/archive/simplify candidates
- mark priorities and dependencies

Outputs:

- cleanup ledger
- truth-source list
- first cut list
- reusable strategy skeleton

This round may include obvious low-risk P0 fixes, but its main purpose is discovery and dependency mapping.

Any Round 1 fix must first be recorded in the ledger and still satisfy the same batch gate used in later rounds.

### Round 2: P0 Cleanup For Live Code And Active Docs

Purpose:

- remove misleading active runtime leftovers
- remove or rewrite active docs that still teach obsolete models
- collapse live compatibility surfaces that survived earlier cutovers

This is the highest-value cleanup round because these surfaces actively mislead ongoing work.

### Round 3: P1 Cleanup For Tests And Helpers

Purpose:

- remove old runtime nouns from `test/test_helper`, fixtures, scenarios, and helper builders
- stop tests from reviving concepts that production already abandoned
- realign verification paths with the actual current model

The goal is to make tests validate the current truth rather than preserve historical scaffolding.

### Round 4: P2 Simplification And Repository Slimming

Purpose:

- simplify ownership and naming where current structure is needlessly non-Rails
- collapse redundant service/helper/lib layers
- review lower-risk tracked clutter that still pollutes the repository view
- archive or delete misleading historical docs encountered during the cleanup

This round focuses on simplification after the misleading active surfaces are already under control.

### Round 5: Retrospective Re-Audit

Purpose:

- rescan the repository using the same discovery method as Round 1
- look specifically for items missed in earlier rounds
- verify that cleanup did not leave mixed old/new truth sources behind

This is a required closeout round, not optional polish.

The cleanup is not complete until this round says the remaining residue is either intentional or logged for a later pass.

## Round Workflow

Each round should follow the same operating loop:

1. scan with a fixed baseline query set plus targeted probes
2. classify findings into the cleanup ledger
3. take only the current highest-priority batch
4. update the relevant code/tests/docs together when a concept is being removed
5. run targeted verification
6. rescan before closing the round
7. record what remains for the next round

This loop exists specifically to avoid the failure mode where a concept is partly deleted but still survives in a second truth source.

## Verification Gates

Verification is required after every cleanup batch and after every round.

### Batch Gate

Before moving a batch to done:

- the targeted old nouns should be absent from active code/doc locations, or explicitly confined to approved historical locations
- touched test paths should pass targeted verification
- any doc move/delete should leave the active truth-source set still coherent

### Round Gate

Before moving to the next round:

- the current priority band should be rescanned
- remaining exceptions should be either deliberate or logged as unresolved findings
- lower-priority work must not begin while unresolved high-priority residue still distorts the active truth

### Final Gate

Before declaring the cleanup complete:

- run the retrospective re-audit
- confirm that no active truth source still teaches abandoned concepts
- confirm that old docs were archived or deleted rather than semantically half-retained
- confirm that the cleanup ledger and the reusable strategy notes are complete

## Dependency Rules

Task ordering should obey these dependencies:

1. establish the truth-source baseline before broad deletion work
2. clean P0 live-path residue before major Rails-shaped simplification
3. clean production truth before cleaning test truth
4. clean test truth before trusting full-suite validation as a signal of conceptual cleanliness
5. finish the retrospective re-audit before closing the project

These dependency rules matter because deleting the wrong abstraction layer too early can hide residue instead of removing it.

## Risk Model

The main risks are:

- leaving mixed old/new truth sources behind
- deleting code in one layer while old nouns remain alive in tests or active docs
- doing aesthetic simplification before the highest-value misleading residue is gone
- losing historical context by deleting materials that should have been archived

Mitigations:

- use the cleanup ledger in every round
- rescan after each round
- couple code/test/doc cleanup when removing a concept
- prefer archive over delete for historical docs that still retain explanatory value
- do not treat passing tests alone as proof that the conceptual cleanup is complete

## Strategy Capture For Reuse

This project should leave behind a reusable cleanup strategy, not only one-off edits.

At minimum, the recorded strategy should preserve:

- baseline scan categories
- classification rules
- priority model
- per-round workflow
- verification gates
- retrospective re-audit method
- common failure modes and how to avoid them

For this task, this design document is the initial reusable strategy record.

Execution should refine that record through the cleanup ledger and implementation artifacts. If the strategy evolves materially during the work, it can be extracted into a later standalone playbook document, but it must not remain implicit.

## Deliverables

The cleanup effort should produce:

- this approved design document
- a follow-on implementation plan
- a cleanup ledger produced during execution
- a recorded reusable cleanup strategy, initially captured in this design lineage and refined during execution
- a final retrospective re-audit result

## Self-Review Checklist For The Design

Before using this design to produce the implementation plan, confirm:

- the scope is explicit
- the non-goals are explicit
- the delete/archive policy is explicit
- the no-`superseded` rule is explicit
- the high-priority-first rule is explicit
- the four-round-plus-review structure is explicit
- verification gates exist at batch, round, and final levels
- dependency ordering is explicit
- reusable strategy capture is explicit

If any of those are missing, the design is incomplete and should be corrected before planning begins.
