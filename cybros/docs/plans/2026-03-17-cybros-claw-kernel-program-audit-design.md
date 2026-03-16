# Cybros / Claw Kernel Program Architecture Audit Design

## Status

Approved on 2026-03-17 for immediate audit planning.

## Goal

Run a code-backed architecture audit across `cybros` and bundled `agents/claw` that treats:

- `cybros` as the kernel/runtime
- `claw` as the program loaded into that runtime

The audit should produce a phaseable refactor package plus an optional big-bang cutover path. Breaking changes are allowed. Compatibility layers are not a goal.

## Context

Recent runtime work already moved the bundled default `claw` path closer to a real external runtime. Existing design docs also already constrain the runtime split:

- `cybros` owns DAG orchestration, transcript state, approvals, compaction, and subagent execution
- `claw` owns prompt assembly, tool catalog, and agent-side hooks

That split is directionally correct, but the codebase still contains experimental agent-side behavior that may now deserve one of three outcomes:

- stay in `claw` as a bounded experiment
- move back into `cybros` as kernel-owned capability
- be deleted or collapsed as redundant structure

`memory` is the clearest example. It was intentionally allowed to live in `claw`-adjacent surfaces for experimentation, but the audit must now reassess whether that still matches the kernel/program boundary.

## Problem

A general cleanup pass or `deslop` run is not enough for the current state of the repository.

The real risk is not only messy code. The risk is architectural drift:

- mixed ownership between `cybros` and `claw`
- shadow runtime logic living in `claw`
- old compatibility surfaces that preserve abandoned models
- documentation that no longer matches the shipped boundary

If those issues are not addressed first, code cleanup will only make the wrong shape cleaner.

## Core Model

### Cybros Is The Kernel

`cybros` owns durable product semantics and system-level runtime behavior, including:

- conversation DAG orchestration
- state transitions and lifecycle control
- approvals and stop/retry semantics
- transcript durability and auditability
- context compaction policy
- subagent orchestration
- persistent system truth that must remain cross-agent consistent
- product-facing documentation of those semantics

### Claw Is The Program

`claw` owns agent-program concerns, including:

- prompt assembly
- tool catalog and tool adapter surfaces
- lightweight hook behavior
- agent profile defaults
- experimental agent-side workflows that are still under evaluation

### Experimental Capability Rule

The audit must not assume that every capability currently in `claw` belongs there permanently.

For each experimental capability, the audit assigns one of three states:

- `stay in claw`
- `move to cybros`
- `delete/collapse`

Migration back into `cybros` is recommended when a capability has become a kernel concern because it now needs durable system semantics, cross-agent consistency, stronger observability, or a single source of truth.

## Audit Questions

Every capability reviewed in the audit should be judged against the same questions:

1. Does it affect conversation or runtime semantics beyond one agent implementation?
2. Does it need to be durable, auditable, or cross-agent consistent?
3. Is ownership split between `cybros` and `claw`, creating drift or duplicated truth?
4. Is it still in `claw` because experimentation speed mattered, rather than because the boundary is correct?

If the answer is "yes" to most of those questions, the capability becomes a migration candidate back into `cybros`.

## Scope

### In Scope

- current runtime and product boundary between `cybros` and bundled `claw`
- ownership of memory, workspace/bootstrap, tool execution surfaces, hook behavior, and runtime policy
- code quality issues that are really symptoms of wrong ownership
- dead code, duplicate abstractions, and compatibility layers created by abandoned models
- performance issues on the main `cybros -> runtime -> claw` execution path
- documentation drift across `README`, `docs/plans`, `docs/product`, `docs/agent_core`, and `docs/dag`
- a phase-based refactor path plus a big-bang cutover appendix

### Out Of Scope

- `nexus` and `mothership`, except where a document or interface in `cybros` depends on them directly
- preserving backward compatibility for abandoned runtime shapes
- broad style-only cleanup with no architectural impact
- speculative product features unrelated to the current shipped runtime split

## Deliverables

The audit should end as a structured package, not as informal notes.

### Primary Deliverables

- `Executive Summary`
- `Kernel / Program Ownership Matrix`
- `Migration Candidate Ledger`
- `Refactor Findings And Actions`
- `Deletion List`
- `Phased Plan`

### Appendix

- `Big-bang Cutover Appendix`

## Findings Taxonomy

Findings should be expressed as explicit actions, not vague observations:

- `move`
- `thin`
- `delete`
- `merge`
- `defer`

Each finding should also be assigned to one of four decision buckets:

- `Must fix in Phase 1`
- `Strong migration candidate`
- `Keep in claw for now, but constrain`
- `Delete now`

## Priority Model

### First Priority

Fix boundary errors first:

- kernel boundary violations
- shadow runtime or shadow policy inside `claw`
- obsolete compatibility surfaces
- mixed-ownership documentation

### Second Priority

Fix high-ROI structural issues:

- mature migration candidates that should move into `cybros`
- areas where `claw` can be substantially thinned
- `cybros` code that exists only to serve an outdated `claw` shape
- obvious hot-path waste in main execution flows

### Third Priority

Run cleanup on the surviving shape:

- dead code
- repetitive helpers
- low-value abstraction
- AI-slop cleanup and style improvement

`deslop` belongs here, not at the start.

## Evidence Model

The audit must be evidence-first.

Conclusions should be grounded in:

- live code paths and ownership boundaries
- recent accepted design and report documents
- existing tests and what they really protect
- targeted verification commands where a boundary judgment needs confirmation

The audit does not need a full monorepo CI run before it can make useful architectural findings. Targeted verification is enough unless a conclusion depends on broader behavior.

## Phase Strategy

### Default Path

The main deliverable should prefer a phased path:

- `Phase 1`: highest-ROI boundary cuts, delete-now items, and obvious ownership cleanup
- `Phase 2`: selected migration candidates back into `cybros`
- `Phase 3`: hot-path performance cleanup and full documentation alignment

### Optional Big-Bang Path

The appendix should also describe the one-shot cutover path if the team decides the architecture drift is easier to fix in a single destructive pass.

## Success Criteria

The audit is successful when:

- every major capability has a single primary owner
- experimental `claw` capabilities are classified as stay/move/delete
- Phase 1 actions are concrete and high-confidence
- delete-now targets are explicit
- document drift is identified against the current codebase
- the team can choose either phased execution or a big-bang cutover without redoing the architecture thinking

## Follow-On Implementation Constraint

After this design, the next implementation artifact should be an execution plan for the audit itself. That plan should be small-step, evidence-first, and optimized for producing the review package before any destructive refactor begins.
