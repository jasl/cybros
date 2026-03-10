# Plans

This directory contains the active rebaseline design docs and executable implementation plans.

Product docs under `docs/product/` are normative. Plans may refine implementation details and sequencing, but they must not redefine product semantics.

Automation note:

- the 2026-03-09 automation-runtime docs are historical
- normative automation semantics live in `docs/product/`
- `2026-03-10-automation-conversation-convergence-design.md` and `2026-03-10-automation-conversation-convergence.md` remain the active convergence rationale and implementation record
- use those 2026-03-10 docs alongside the product docs for audit, implementation, and code-review work
- any sections explicitly marked as pre-cut code, conflict inventory, or historical red-phase expectations are trace only and must not be treated as the current runtime contract

## Active Design Sources

- `2026-03-09-programmable-agent-preflight-design.md`
- `2026-03-08-phase-1-schema-cut-list.md`
- `2026-03-08-runtime-governance-design.md`
- `2026-03-09-execution-target-discovery-design.md`
- `2026-03-09-permission-presets-design.md`
- `2026-03-09-agent-deployment-connection-design.md`
- `2026-03-10-automation-conversation-convergence-design.md`

## Active Executable Plans

- `2026-03-08-runtime-governance.md`
- `2026-03-09-agent-deployment-connection.md`
- `2026-03-10-automation-conversation-convergence.md`

## Historical But Superseded

- `2026-03-09-automation-runtime-design.md`
- `2026-03-09-automation-runtime.md`
- `2026-03-09-execution-capacity-and-scheduled-automation.md`

## Ownership Rules

- product contract lives in `docs/product/`
- schema-cut guidance lives in `2026-03-08-phase-1-schema-cut-list.md`
- runtime-governance plan owns provider, runtime-settings, execution-location, workspace, and execution-target schema plus admission primitives
- agent-deployment plan owns programmable-agent lifecycle, drafts, permission presets, target inventory APIs, conversation runtime selectors, and replay-safe RPC
- automation convergence plan owns automation domain/runtime behavior on top of the canonical run lifecycle

## Recommended Execution Order

1. Read product docs, then `2026-03-09-programmable-agent-preflight-design.md`.
2. Apply `2026-03-08-phase-1-schema-cut-list.md`.
3. Execute `2026-03-08-runtime-governance.md` Task 1 before any plan consumes execution locations, workspaces, or execution targets.
4. Execute `2026-03-09-agent-deployment-connection.md` Task 1 through Task 3 so deployment lifecycle exists before draft planning depends on it.
5. Execute `2026-03-08-runtime-governance.md` Task 2 through Task 5.
6. Execute `2026-03-09-agent-deployment-connection.md` Task 4 through Task 7.
7. Execute `2026-03-10-automation-conversation-convergence.md`.
8. Finish with E2E, observability, and operator-surface cleanup across all three plans.

## Plan Hygiene

- executable plans should own tasks, tests, and sequencing
- design docs should explain invariants and ownership, not restate task lists
- if a plan conflicts with product docs or preflight, stop and rewrite the plan first
