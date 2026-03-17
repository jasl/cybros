# Plans

This directory contains active design docs and executable plans that still matter to current or next-step work.

Product docs under `docs/product/` remain normative. Plans may refine implementation details and sequencing, but they should not silently redefine product semantics.

When a plan is fully landed or intentionally abandoned, move it to `docs/archive/plans/YYYY-MM/`.

## Current Focus Areas

- agent-bound runtime cleanup and leftover execution-target removal
- agent-root workspace and operation-sequence cutover
- automation convergence
- permission preset cleanup
- DAG hot-path / turn-first read-path cleanup
- bootstrap hooks / authority tasks
- turn-internal append-task orchestration
- bundled claw runtime boundary audit

## Active Design Sources

- `2026-03-09-permission-presets-design.md`
- `2026-03-11-turn-bundle-hot-path-design.md`
- `2026-03-12-bootstrap-hooks-and-authority-tasks-design.md`
- `2026-03-12-append-task-internal-queue-design.md`
- `2026-03-13-conversation-agent-runtime-simplification-design.md`
- `2026-03-16-agent-root-workspace-design.md`
- `2026-03-16-bundled-claw-external-runtime-design.md`
- `2026-03-17-conversation-composer-drafts-design.md`
- `2026-03-17-cybros-claw-kernel-program-audit-design.md`
- `2026-03-17-cybros-main-app-cleanup-design.md`
- `2026-03-17-operation-sequence-cutover-design.md`

## Active Executable Plans

- `2026-03-10-automation-conversation-convergence.md`
- `2026-03-11-turn-bundle-hot-path.md`
- `2026-03-12-bootstrap-hooks-and-authority-tasks.md`
- `2026-03-12-append-task-internal-queue.md`
- `2026-03-13-conversation-agent-runtime-simplification.md`
- `2026-03-16-agent-root-workspace.md`
- `2026-03-16-bundled-claw-external-runtime.md`
- `2026-03-17-conversation-composer-drafts.md`
- `2026-03-17-cybros-claw-kernel-program-audit.md`
- `2026-03-17-cybros-main-app-cleanup.md`
- `2026-03-17-operation-sequence-cutover.md`

## Recently Archived

- `2026-03-08-runtime-governance*`
- `2026-03-09-automation-runtime*`
- `2026-03-11-lane-state-prompt-buffer-*`
- `2026-03-11-context-budget-soft-limit-*`
- `2026-03-11-turn-head-lane-seq-rename-*`
- `2026-03-09-agent-deployment-connection*`
- `2026-03-09-execution-target-discovery-design*`
- `2026-03-09-programmable-agent-preflight-*`
- `2026-03-09-programmable-agent-rebaseline-repair*`
- `2026-03-09-runtime-governance-operator-surfaces*`
- `2026-03-10-automation-conversation-convergence-design*`
- `2026-03-10-bundled-default-external-agent*`
- `2026-03-10-programmable-agent-reaudit-remediation*`
- `2026-03-11-agent-hooks-capabilities-runtime-*`

These now live under `docs/archive/plans/2026-03/` because the corresponding runtime migrations have landed or been superseded by newer product/docs state.

## Ownership Rules

- product contract lives in `docs/product/`
- runtime cleanup plans own deletion of old execution-target, deployment, and workspace surfaces from the product path
- permission-preset plans own user-facing permission semantics
- automation convergence plans own automation behavior on top of the canonical run lifecycle
- workspace and operation-sequence plans own the current runtime/workspace boundary and execution ordering model

## Plan Hygiene

- executable plans own tasks, tests, and sequencing
- design docs explain invariants and ownership; they should not duplicate task lists
- if a plan conflicts with shipped code or product docs, update the plan before implementation resumes
