# Turn Head / Lane Seq Rename Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename the DAG turn-visibility vocabulary from `anchor`/`anchored_seq` to `head`/`lane_seq` everywhere in active code, schema, tests, and docs without keeping compatibility aliases.

**Architecture:** This is a destructive terminology cut, not a behavior refactor. Keep the existing DAG model and semantics, rename the persisted columns and public helpers in one pass, then update all hot-path design docs and runtime docs to speak in the new vocabulary.

**Tech Stack:** Ruby on Rails, PostgreSQL, ActiveRecord, DAG runtime, test suite under `cybros/test`, active docs under `cybros/docs`

---

### Task 1: Lock The Rename Surface With Failing Schema And API Tests

**Files:**
- Modify: `cybros/test/models/dag/lane_turns_test.rb`
- Move: `cybros/test/models/dag/turn_anchor_maintenance_test.rb` -> `cybros/test/models/dag/turn_head_maintenance_test.rb`
- Modify: `cybros/test/models/conversation/turn_execution_projector_test.rb`
- Modify: `cybros/test/lib/dag/graph_audit_test.rb`
- Create: `cybros/test/models/dag/turn_head_rename_test.rb`

**Step 1: Write the failing test**

Cover:

- turn records expose `head_node_id` and `lane_seq`, not `anchor_node_id` and `anchored_seq`
- lane helpers expose `lane_turn_page/count/seq_for`, not anchored variants
- turn execution projection exposes `head_node_id`
- graph audit and maintenance use head terminology in outputs

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/models/dag/lane_turns_test.rb cybros/test/models/dag/turn_head_maintenance_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb cybros/test/lib/dag/graph_audit_test.rb cybros/test/models/dag/turn_head_rename_test.rb`

Expected: FAIL because current schema and APIs still use anchor/anchored terminology.

**Step 3: Write minimal implementation**

Implement only enough red-phase fixture/setup changes to describe the renamed contract clearly.

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/models/dag/lane_turns_test.rb cybros/test/models/dag/turn_head_maintenance_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb cybros/test/lib/dag/graph_audit_test.rb cybros/test/models/dag/turn_head_rename_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/test/models/dag/lane_turns_test.rb cybros/test/models/dag/turn_head_maintenance_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb cybros/test/lib/dag/graph_audit_test.rb cybros/test/models/dag/turn_head_rename_test.rb
git commit -m "test: lock turn head rename contract"
```

### Task 2: Rename Schema And Model APIs In One Destructive Cut

**Files:**
- Modify: `cybros/db/migrate/20260217000000_create_dag_workflow_engine.rb`
- Modify: `cybros/db/schema.rb`
- Modify: `cybros/app/models/dag/turn.rb`
- Modify: `cybros/app/models/dag/lane.rb`
- Modify: `cybros/app/models/dag/graph.rb`
- Modify: `cybros/app/models/dag/node.rb`
- Modify: `cybros/app/models/dag/node_body.rb`
- Modify: `cybros/app/models/messages/user_message.rb`
- Modify: `cybros/app/models/messages/agent_message.rb`
- Test: `cybros/test/models/dag/lane_turns_test.rb`
- Test: `cybros/test/models/dag/turn_head_rename_test.rb`

**Step 1: Write the failing test**

Cover:

- renamed columns exist on `dag_turns` / `dag_lanes`
- model helpers and hook names use `head` / `lane_seq`
- no active code path still references the old column/helper names

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/models/dag/lane_turns_test.rb cybros/test/models/dag/turn_head_rename_test.rb`

Expected: FAIL because schema and model APIs still use the old vocabulary.

**Step 3: Write minimal implementation**

Implement:

- edit the defining migration in place; do not add a compatibility migration
- column rename cut (`anchor_*` -> `head_*`, `anchored_seq` -> `lane_seq`, `next_anchored_seq` -> `next_lane_seq`)
- update affected partial index definitions to reference the renamed columns
- rename schema object names that still literally contain the old vocabulary, including:
  - `index_dag_turns_graph_lane_anchored_seq_unique`
  - `check_dag_turns_anchor_fields_consistent`
  - `check_dag_turns_anchor_including_deleted_fields_consistent`
  - `check_dag_turns_anchored_seq_positive`
- helper rename cut on turn/lane/graph/node APIs
- hook rename cut from `turn_anchor?` to `turn_head?`
- no compatibility aliases; update all direct callers instead

**Step 4: Run test to verify it passes**

Run: `bin/rails db:reset`

Run: `rg -n "anchor_created_at|anchor_node_id|anchored_seq|next_anchored_seq|check_dag_turns_anchor|check_dag_turns_anchored_seq|index_dag_turns_graph_lane_anchored_seq_unique" cybros/db/schema.rb`

Run: `bin/rails test cybros/test/models/dag/lane_turns_test.rb cybros/test/models/dag/turn_head_rename_test.rb`

Expected: schema search returns no matches and tests PASS

**Step 5: Commit**

```bash
git add cybros/db/schema.rb cybros/app/models/dag/turn.rb cybros/app/models/dag/lane.rb cybros/app/models/dag/graph.rb cybros/app/models/dag/node.rb cybros/app/models/dag/node_body.rb cybros/app/models/messages/user_message.rb cybros/app/models/messages/agent_message.rb
git commit -m "refactor: rename turn anchors to heads"
```

### Task 3: Rename Runtime Maintenance, Audit, And Projectors

**Files:**
- Move: `cybros/lib/dag/turn_anchor_maintenance.rb` -> `cybros/lib/dag/turn_head_maintenance.rb`
- Modify: `cybros/lib/dag/compression.rb`
- Modify: `cybros/lib/dag/context_window_assembly.rb`
- Modify: `cybros/lib/dag/graph_audit.rb`
- Modify: `cybros/lib/dag/mutations.rb`
- Modify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/dag/graph_hooks.rb`
- Test: `cybros/test/models/dag/turn_head_maintenance_test.rb`
- Test: `cybros/test/lib/dag/graph_audit_test.rb`
- Test: `cybros/test/models/conversation/turn_execution_projector_test.rb`

**Step 1: Write the failing test**

Cover:

- maintenance code refreshes turn heads, not turn anchors
- audit issues and diagnostics speak in head terminology
- projection payloads expose `head_node_id`
- runtime maintenance callers no longer mention anchor names

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/models/dag/turn_head_maintenance_test.rb cybros/test/lib/dag/graph_audit_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb`

Expected: FAIL because runtime maintenance, audit, and projector code still emit the old names.

**Step 3: Write minimal implementation**

Implement:

- file/class rename to `TurnHeadMaintenance`
- all runtime callers updated to the new class and helper names
- audit issue payloads and projector payloads rewritten to head/lane_seq vocabulary

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/models/dag/turn_head_maintenance_test.rb cybros/test/lib/dag/graph_audit_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/dag/turn_head_maintenance.rb cybros/lib/dag/compression.rb cybros/lib/dag/context_window_assembly.rb cybros/lib/dag/graph_audit.rb cybros/lib/dag/mutations.rb cybros/app/models/conversation/turn_execution_projector.rb cybros/app/models/conversation.rb cybros/app/models/dag/graph_hooks.rb cybros/test/models/dag/turn_head_maintenance_test.rb cybros/test/lib/dag/graph_audit_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb
git commit -m "refactor: rename turn head runtime maintenance"
```

### Task 4: Rewrite Active Docs And Plans To The New Vocabulary

**Files:**
- Modify: `cybros/docs/dag/public_api.md`
- Modify: `cybros/docs/dag/workflow_engine.md`
- Modify: `cybros/docs/dag/behavior_spec.md`
- Modify: `cybros/docs/dag/audit.md`
- Modify: `cybros/docs/agent_core/behavior_spec.md`
- Modify: `cybros/docs/agent_core/node_payloads.md`
- Modify: `cybros/docs/plans/2026-03-11-turn-bundle-hot-path-design.md`
- Modify: `cybros/docs/plans/2026-03-11-turn-bundle-hot-path.md`
- Modify: `cybros/docs/plans/2026-03-11-turn-head-lane-seq-rename-design.md`
- Move: `cybros/docs/plans/2026-03-11-turn-head-lane-seq-rename-design.md` -> `cybros/docs/archive/plans/2026-03/2026-03-11-turn-head-lane-seq-rename-design.md`
- Move: `cybros/docs/plans/2026-03-11-turn-head-lane-seq-rename.md` -> `cybros/docs/archive/plans/2026-03/2026-03-11-turn-head-lane-seq-rename.md`

**Step 1: Write the failing doc checklist**

Cover:

- active docs use `turn head` / `lane_seq`
- no active doc still treats `anchor` terminology as current contract
- docs clearly state that turn head is the public node for transcript-oriented surfaces
- unrelated branch/fork anchor terminology is left alone unless it actually means a turn head

**Step 2: Run doc review to verify it fails**

Run: `rg -n "anchor_node_id|anchor_created_at|anchor_node_id_including_deleted|anchor_created_at_including_deleted|anchored_seq|next_anchored_seq|TurnAnchorMaintenance|turn_anchor\\?|turn_anchor_drift|missing_turn_anchor_node_type|anchored_turn_|turn anchor|anchored turns|可见锚点" cybros/docs --glob '!cybros/docs/archive/**'`

Expected: matches remain in active docs before rewrite.

**Step 3: Write minimal documentation updates**

Implement:

- normative doc rewrites to head/lane_seq wording
- audit/diagnostic doc wording and issue codes rewritten to head terminology
- plan/doc rewrites so new work starts from the renamed vocabulary
- archive the rename design/plan pair after execution because they intentionally preserve pre-cut terminology
- preserve other archive docs unless they are still referenced as active

**Step 4: Run doc review to verify it passes**

Run: `rg -n "anchor_node_id|anchor_created_at|anchor_node_id_including_deleted|anchor_created_at_including_deleted|anchored_seq|next_anchored_seq|TurnAnchorMaintenance|turn_anchor\\?|turn_anchor_drift|missing_turn_anchor_node_type|anchored_turn_|turn anchor|anchored turns|可见锚点" cybros/docs --glob '!cybros/docs/archive/**'`

Expected: no matches in active docs.

**Step 5: Commit**

```bash
git add cybros/docs/dag/public_api.md cybros/docs/dag/workflow_engine.md cybros/docs/dag/behavior_spec.md cybros/docs/dag/audit.md cybros/docs/agent_core/behavior_spec.md cybros/docs/agent_core/node_payloads.md cybros/docs/plans/2026-03-11-turn-bundle-hot-path-design.md cybros/docs/plans/2026-03-11-turn-bundle-hot-path.md cybros/docs/archive/plans/2026-03/2026-03-11-turn-head-lane-seq-rename-design.md cybros/docs/archive/plans/2026-03/2026-03-11-turn-head-lane-seq-rename.md
git commit -m "docs: rename turn anchors to heads"
```

### Task 5: Run Full Search And Verification Before Declaring The Cut Complete

**Files:**
- Modify: any remaining active code/test/doc files surfaced by search
- Likely cleanup tail from current search:
  - `cybros/test/models/dag/db_constraints_test.rb`
  - `cybros/test/models/dag/large_graph_extremes_test.rb`
  - `cybros/test/scenarios/dag/auto_roleplay_no_human_flow_test.rb`
  - `cybros/test/scenarios/dag/stale_queued_reply_guard_flow_test.rb`

**Step 1: Write the failing verification checklist**

Cover:

- no active Ruby/test/doc reference still uses old terminology
- no schema/model/runtime/test mismatch remains
- no public payload still emits `anchor_node_id` or `anchored_seq`
- no active audit/diagnostic issue code still emits `turn_anchor_drift`

**Step 2: Run verification to verify it fails before cleanup**

Run: `rg -n "anchor_node_id|anchor_created_at|anchor_node_id_including_deleted|anchor_created_at_including_deleted|anchored_seq|next_anchored_seq|TurnAnchorMaintenance|turn_anchor\\?|turn_anchor_drift|turn_anchor_node|anchored_turn_|expected_tail_anchor_node_id|actual_tail_anchor_node_id" cybros/app cybros/lib cybros/test cybros/docs --glob '!cybros/docs/archive/**'`

Expected: any remaining matches are the final cleanup list.

**Step 3: Write minimal cleanup**

Implement:

- remove the remaining active references
- rename affected test classes/files if needed
- keep archive-only references untouched unless promoted back to active use

**Step 4: Run final verification**

Run: `bin/rails db:reset`

Run: `rg -n "anchor_created_at|anchor_node_id|anchored_seq|next_anchored_seq|check_dag_turns_anchor|check_dag_turns_anchored_seq|index_dag_turns_graph_lane_anchored_seq_unique" cybros/db/schema.rb`

Run: `bin/rails test cybros/test/models/dag/lane_turns_test.rb cybros/test/models/dag/turn_head_maintenance_test.rb cybros/test/models/conversation/turn_execution_projector_test.rb cybros/test/lib/dag/graph_audit_test.rb`

Run: `rg -n "anchor_node_id|anchor_created_at|anchor_node_id_including_deleted|anchor_created_at_including_deleted|anchored_seq|next_anchored_seq|TurnAnchorMaintenance|turn_anchor\\?|turn_anchor_drift|turn_anchor_node|anchored_turn_|expected_tail_anchor_node_id|actual_tail_anchor_node_id" cybros/app cybros/lib cybros/test cybros/docs --glob '!cybros/docs/archive/**'`

Expected: schema search returns no matches, tests PASS, and active code/test/doc search returns no old turn-visibility names.

**Step 5: Commit**

```bash
git add cybros/app cybros/lib cybros/test cybros/docs cybros/db/schema.rb
git commit -m "chore: complete turn head terminology cut"
```
