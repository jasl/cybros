# Turn Bundle Hot Path Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Improve long-conversation performance and code quality by making turn/bundle projections the default hot path without introducing any new DAG entity.

**Architecture:** Keep the existing single-layer DAG. Tighten the read/runtime boundary so transcript and conversation hot paths are turn-first, add a small set of rollup/cache facts on `dag_turns`, and use existing compression/visibility semantics to fold stable internal activity off the default path.

**Tech Stack:** Ruby on Rails, PostgreSQL, DAG runtime, ActiveRecord, existing turn/lane/transcript/compression APIs

---

### Task 1: Lock Long-Turn Performance Expectations With Red Tests

**Files:**
- Modify: `cybros/test/lib/dag/context_window_assembly_test.rb`
- Modify: `cybros/test/models/dag/transcript_recent_turns_test.rb`
- Modify: `cybros/test/models/conversation/turn_execution_projector_test.rb`
- Create: `cybros/test/models/dag/turn_rollup_hot_path_test.rb`

**Step 1: Write the failing test**

Cover:

- task-heavy turns still produce a small transcript payload without pulling task detail into the main transcript projection
- turn execution projection still exposes internal tasks/subagents when explicitly requested
- context-window assembly on a task-heavy turn only includes the nodes that the selected turn/context policy actually needs
- turn-level rollup fields stay coherent when a turn gains tasks, finishes, or is compacted

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/lib/dag/context_window_assembly_test.rb cybros/test/models/dag/transcript_recent_turns_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb cybros/test/models/dag/turn_rollup_hot_path_test.rb`

Expected: FAIL on missing rollup fields and unchanged hot-path behavior.

**Step 3: Write minimal implementation**

Implement only enough scaffolding to express the desired hot-path contract in test setup helpers and schema expectations.

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/lib/dag/context_window_assembly_test.rb cybros/test/models/dag/transcript_recent_turns_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb cybros/test/models/dag/turn_rollup_hot_path_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/test/lib/dag/context_window_assembly_test.rb cybros/test/models/dag/transcript_recent_turns_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb cybros/test/models/dag/turn_rollup_hot_path_test.rb
git commit -m "test: lock turn bundle hot path expectations"
```

### Task 2: Make Transcript And Conversation Reads Strictly Turn-First

**Files:**
- Modify: `cybros/app/models/dag/lane.rb`
- Modify: `cybros/app/models/dag/graph.rb`
- Modify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Modify: `cybros/app/models/conversation.rb`
- Test: `cybros/test/models/dag/transcript_recent_turns_test.rb`
- Test: `cybros/test/models/conversation/turn_execution_projection_visibility_test.rb`
- Test: `cybros/test/models/conversation/turn_execution_projector_test.rb`

**Step 1: Write the failing test**

Cover:

- transcript paths resolve visible turn ids first and only then load transcript candidates
- preflight/composer-only activity stays out of the assistant-bubble hot path
- turn execution drill-down is explicit and does not change transcript payload shape

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/models/dag/transcript_recent_turns_test.rb cybros/test/models/conversation/turn_execution_projection_visibility_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb`

Expected: FAIL because current code still mixes more node/task detail into hot paths than desired.

**Step 3: Write minimal implementation**

Implement:

- a stricter split between transcript projection and turn execution drill-down
- shared helpers for "turn-first visible transcript" vs "expanded execution detail"
- removal of incidental task-detail loading from default conversation read flows

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/models/dag/transcript_recent_turns_test.rb cybros/test/models/conversation/turn_execution_projection_visibility_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/app/models/dag/lane.rb cybros/app/models/dag/graph.rb cybros/app/models/conversation/turn_execution_projector.rb cybros/app/models/conversation.rb cybros/test/models/dag/transcript_recent_turns_test.rb cybros/test/models/conversation/turn_execution_projection_visibility_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb
git commit -m "refactor: make conversation reads turn first"
```

### Task 3: Add Turn Rollups On `dag_turns`

**Files:**
- Modify: migration/schema files that define `dag_turns`
- Modify: `cybros/db/schema.rb`
- Modify: `cybros/app/models/dag/turn.rb`
- Modify: `cybros/lib/dag/turn_head_maintenance.rb`
- Modify: `cybros/app/models/dag/graph.rb`
- Test: `cybros/test/models/dag/lane_turns_test.rb`
- Test: `cybros/test/models/dag/turn_rollup_hot_path_test.rb`

**Step 1: Write the failing test**

Cover:

- turn rollup fields update when head visibility changes
- turn rollup fields update when task-heavy activity changes execution state
- compacted turns keep coherent public rollup state

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/models/dag/lane_turns_test.rb cybros/test/models/dag/turn_rollup_hot_path_test.rb`

Expected: FAIL because the rollup/cache fields do not exist or are not maintained.

**Step 3: Write minimal implementation**

Implement:

- new `dag_turns` rollup/cache columns
- maintenance hooks piggybacking on existing turn-head refresh and turn state transitions
- model helpers that expose rollup facts without forcing node scans

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/models/dag/lane_turns_test.rb cybros/test/models/dag/turn_rollup_hot_path_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/db/schema.rb cybros/app/models/dag/turn.rb cybros/lib/dag/turn_head_maintenance.rb cybros/app/models/dag/graph.rb cybros/test/models/dag/lane_turns_test.rb cybros/test/models/dag/turn_rollup_hot_path_test.rb
git commit -m "feat: add turn rollups for hot paths"
```

### Task 4: Teach Context Assembly To Use Turn Rollups Before Node Expansion

**Files:**
- Modify: `cybros/lib/dag/context_window_assembly.rb`
- Modify: `cybros/lib/agent_core/dag/context_budget_manager.rb`
- Modify: `cybros/app/models/dag/graph.rb`
- Test: `cybros/test/lib/dag/context_window_assembly_test.rb`
- Test: `cybros/test/models/dag/large_graph_extremes_test.rb`
- Test: `cybros/test/scenarios/dag/context_overflow_compaction_flow_test.rb`

**Step 1: Write the failing test**

Cover:

- selected turns are pruned at the turn layer before full node loading
- task-heavy historical turns do not force full internal-node expansion unless required for context semantics
- budget manager still produces the same visible context semantics after the optimization

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/lib/dag/context_window_assembly_test.rb cybros/test/models/dag/large_graph_extremes_test.rb cybros/test/scenarios/dag/context_overflow_compaction_flow_test.rb`

Expected: FAIL because context assembly still loads all active nodes inside selected turns.

**Step 3: Write minimal implementation**

Implement:

- turn-rollup-guided turn selection
- narrower node/body loading for context assembly
- compatibility logic that keeps safety limits and transcript semantics unchanged

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/lib/dag/context_window_assembly_test.rb cybros/test/models/dag/large_graph_extremes_test.rb cybros/test/scenarios/dag/context_overflow_compaction_flow_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/dag/context_window_assembly.rb cybros/lib/agent_core/dag/context_budget_manager.rb cybros/app/models/dag/graph.rb cybros/test/lib/dag/context_window_assembly_test.rb cybros/test/models/dag/large_graph_extremes_test.rb cybros/test/scenarios/dag/context_overflow_compaction_flow_test.rb
git commit -m "perf: prune context assembly by turn rollups"
```

### Task 5: Fold Stable Internal Activity Off The Default Path

**Files:**
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/dag/lane.rb`
- Modify: `cybros/lib/dag/compression.rb`
- Modify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Test: `cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb`
- Test: `cybros/test/scenarios/dag/steer_current_turn_flow_test.rb`
- Test: `cybros/test/integration/retry_generation_test.rb`

**Step 1: Write the failing test**

Cover:

- stable task-heavy turns can be folded using existing compression/visibility semantics
- folded internal activity stays available to audit/drill-down flows
- default transcript/conversation paths stop paying for folded internal detail

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb cybros/test/scenarios/dag/steer_current_turn_flow_test.rb cybros/test/integration/retry_generation_test.rb`

Expected: FAIL because stable internal detail is still carried on the hot path.

**Step 3: Write minimal implementation**

Implement:

- stable-turn folding rules using existing `compressed_at`, summary-node, and context-visibility semantics
- projector compatibility so drill-down still exposes audit history
- conservative guards so running/pending execution is never folded incorrectly

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb cybros/test/scenarios/dag/steer_current_turn_flow_test.rb cybros/test/integration/retry_generation_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/app/models/conversation.rb cybros/app/models/dag/lane.rb cybros/lib/dag/compression.rb cybros/app/models/conversation/turn_execution_projector.rb cybros/test/scenarios/dag/agent_core_dag_integration_flow_test.rb cybros/test/scenarios/dag/steer_current_turn_flow_test.rb cybros/test/integration/retry_generation_test.rb
git commit -m "perf: fold stable internal turn activity"
```

### Task 6: Refresh Docs And Operator Guidance

**Files:**
- Modify: `cybros/docs/dag/public_api.md`
- Modify: `cybros/docs/agent_core/context_management.md`
- Modify: `cybros/docs/plans/2026-03-11-context-budget-soft-limit-design.md`
- Modify: `cybros/docs/plans/2026-03-11-turn-bundle-hot-path-design.md`

**Step 1: Write the failing doc checklist**

Cover:

- turn-first hot-path boundary
- `dag_turns` rollup ownership
- stable-turn folding semantics
- interaction with context-budget compaction

**Step 2: Run doc review to verify gaps**

Run: manual review against touched runtime paths and plan docs.

Expected: gaps between docs and landed behavior are visible before rewrite.

**Step 3: Write minimal documentation updates**

Implement:

- public API guidance that reinforces turn-first reads
- context-management guidance that explains how turn-heavy conversations stay efficient
- design docs that reflect the final cut

**Step 4: Run final verification**

Run: `bin/rails test cybros/test/lib/dag/context_window_assembly_test.rb cybros/test/models/dag/transcript_recent_turns_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb cybros/test/models/dag/turn_rollup_hot_path_test.rb cybros/test/models/dag/large_graph_extremes_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/docs/dag/public_api.md cybros/docs/agent_core/context_management.md cybros/docs/plans/2026-03-11-context-budget-soft-limit-design.md cybros/docs/plans/2026-03-11-turn-bundle-hot-path-design.md
git commit -m "docs: describe turn bundle hot path model"
```
