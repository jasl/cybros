# Turn Bundle Hot Path Design

## Status

Approved design notes for improving long-conversation performance and code quality without introducing a new DAG entity.

Checkpoint note for the 2026-03-11 cut:

- keep assistant-bubble `run_state` on the current `bounded preview + summary` contract
- do not switch this batch to `summary-only`
- treat any future `summary-only` cut as a separate product/UI contract change, not as implicit scope inside the current hot-path rollout

## Problem

The current DAG model already has the semantics needed for a "black-box task bundle":

- one user-to-agent exchange shares a `turn_id`
- transcript/UI surfaces already prefer turn/message projections
- task and subagent internals remain observable through turn execution projection
- stable history can already be folded through existing compression and visibility controls

The remaining gap is operational, not conceptual:

- long conversations still pay for node/edge-heavy turns in read paths
- context assembly still loads all active nodes inside selected turns
- turn execution details are available, but not strongly isolated from hot UI/runtime paths

## Core Decision

Do not add `junction`, `bundle`, or any new persisted DAG entity.

Instead:

- treat each turn on the lane trunk as the macro execution boundary
- treat the turn head plus projected turn execution as the public "head" of that boundary
- optimize hot paths to stay turn-first by default and expand internal nodes only on demand

This preserves the current graph model while making the code reflect the intended abstraction more clearly.

## Optimization Strategy

### 1. Turn-first read paths

The default product path should work from `dag_turns` outward, not from `dag_nodes` inward.

Concretely:

- transcript and main conversation rendering should resolve visible turns first
- turn execution activity details should stay behind explicit drill-down/projector calls
- preflight and composer-only activities should not contaminate the primary assistant-bubble path

This is primarily a code-quality change with moderate performance benefit.

### 2. Turn rollups on existing `dag_turns`

Add a small set of turn-level rollup/cache fields to the existing turn record rather than inventing a new table or node type.

Candidate rollups:

- stable public head/reference node ids
- turn status rollup
- last-updated timestamp for execution activity
- internal activity counts
- optional coarse token-cost facts for context selection

These rollups let hot paths prune and order turns before loading internal nodes.

This is the highest-value performance change for long conversations that contain heavy tool/subagent activity inside a single turn.

### 3. Stable-turn internal folding

Once a turn becomes stable, use existing mechanisms more aggressively:

- `compressed_at` / summary-node flow
- `context_excluded_at`
- transcript candidate filtering

The goal is not to hide audit history, but to keep stable internal execution detail off the default hot path.

This phase should only build on existing compression/visibility semantics. It must not introduce a hierarchical graph model.

## Code-Quality Goal

After this change, the codebase should make one boundary explicit:

- public conversation/read APIs operate on turn/message projections
- internal execution detail is behind turn execution projection and explicit drill-down

That boundary reduces the amount of app/runtime code that needs to understand raw task/subagent node structure.

## Expected Performance Wins

Most likely wins:

- faster transcript loading for long conversations
- more stable turn list / message list performance
- less node/body/event loading for collapsed or non-expanded turns
- less context-window work caused by internal task-heavy turns

Less direct or later wins:

- scheduler improvements
- graph-wide diagnostics
- cross-lane heavy scans

## Non-Goals

- no new DAG primitive
- no nested subgraph model
- no replacement of `turn_id`
- no change to auditability requirements

## Implementation Order

1. Make transcript and turn execution paths more strictly turn-first.
2. Add turn-level rollups/caches on `dag_turns`.
3. Use existing folding/compression/visibility semantics to keep stable internal detail off hot paths.

## Relationship To Context-Budget Work

This design complements context-budget soft limits and agent-driven `compact_context`:

- heavy single-turn tool/subagent activity is expected in vibe-coding scenarios
- long-turn complexity should be treated as normal, not exceptional
- turn-first hot paths make that workload sustainable without inventing a new graph abstraction
