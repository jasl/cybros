# Plans

This directory contains active design docs and executable plans that still matter to current or next-step work.

Product docs under `docs/product/` remain normative. Plans may refine implementation details and sequencing, but they should not silently redefine product semantics.

When a plan is fully landed or intentionally abandoned, move it to `docs/archive/plans/YYYY-MM/`.

## Current Focus Areas

- deployment lifecycle and activation
- runtime governance and execution-target selection
- automation convergence
- DAG hot-path / turn-first read-path cleanup

## Active Design Sources

- `2026-03-08-runtime-governance-design.md`
- `2026-03-09-agent-deployment-connection-design.md`
- `2026-03-09-execution-target-discovery-design.md`
- `2026-03-09-permission-presets-design.md`
- `2026-03-11-turn-bundle-hot-path-design.md`

## Active Executable Plans

- `2026-03-08-runtime-governance.md`
- `2026-03-10-automation-conversation-convergence.md`
- `2026-03-11-turn-bundle-hot-path.md`

## Recently Archived

- `2026-03-11-lane-state-prompt-buffer-*`
- `2026-03-11-context-budget-soft-limit-*`
- `2026-03-11-turn-head-lane-seq-rename-*`
- `2026-03-09-agent-deployment-connection*`
- `2026-03-09-programmable-agent-preflight-*`
- `2026-03-09-programmable-agent-rebaseline-repair*`
- `2026-03-10-automation-conversation-convergence-design*`
- `2026-03-10-bundled-default-external-agent*`
- `2026-03-10-programmable-agent-reaudit-remediation*`
- `2026-03-11-agent-hooks-capabilities-runtime-*`

These now live under `docs/archive/plans/2026-03/` because the corresponding runtime migrations have landed or been superseded by newer product/docs state.

## Ownership Rules

- product contract lives in `docs/product/`
- runtime-governance plans own provider/runtime-governor/execution-target schema and admission primitives
- agent-deployment plans own programmable-agent lifecycle, drafts, permission presets, target inventory APIs, and replay-safe RPC
- automation convergence plans own automation behavior on top of the canonical run lifecycle

## Plan Hygiene

- executable plans own tasks, tests, and sequencing
- design docs explain invariants and ownership; they should not duplicate task lists
- if a plan conflicts with shipped code or product docs, update the plan before implementation resumes
