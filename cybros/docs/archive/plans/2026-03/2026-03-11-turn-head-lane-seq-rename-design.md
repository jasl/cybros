# Turn Head / Lane Seq Rename Design

## Status

Approved destructive rename cut for DAG turn visibility terminology.

## Why Rename

The existing DAG concepts already express the desired model:

- `turn` is the macro execution boundary on a lane trunk
- one turn may contain preflight, tool loop, subagent work, and final output
- one public node represents that turn to transcript-oriented product surfaces

The misleading part is the current vocabulary:

- `anchor` sounds like an implementation detail, not the public node users and product code should think in
- `anchored_seq` sounds tied to anchoring mechanics, not to trunk order

The rename should make the existing semantics explicit instead of introducing a new concept.

## Core Decision

Perform one destructive terminology cut:

- `turn_anchor` family becomes `turn_head`
- `anchored_seq` family becomes `lane_seq`

No compatibility layer.
No aliases.
No dual-write period.
Database reset is acceptable.

## New Semantic Wording

- `turn`: the macro execution boundary for one exchange on a lane trunk
- `turn head`: the public node that represents that turn in transcript-oriented surfaces
- `lane_seq`: the monotonic trunk-order sequence for turns inside one lane

This preserves the graph model while making the intended abstraction legible in code and docs.

## Rename Matrix

### Turn head family

- `turn_anchor?` -> `turn_head?`
- `turn_anchor_node_types` -> `turn_head_node_types`
- `turn_anchor_node_ids` -> `turn_head_node_ids`
- `TurnAnchorMaintenance` -> `TurnHeadMaintenance`
- `anchor_node_id` -> `head_node_id`
- `anchor_created_at` -> `head_created_at`
- `anchor_node_id_including_deleted` -> `head_node_id_including_deleted`
- `anchor_created_at_including_deleted` -> `head_created_at_including_deleted`

### Lane sequence family

- `anchored_seq` -> `lane_seq`
- `next_anchored_seq` -> `next_lane_seq`
- `anchored_turn_page` -> `lane_turn_page`
- `anchored_turn_count` -> `lane_turn_count`
- `anchored_turn_seq_for` -> `lane_turn_seq_for`

### Audit / diagnostics family

- `turn_anchor_drift` -> `turn_head_drift`
- `missing_turn_anchor_node_type` -> `missing_turn_head_node_type`

## Scope

Must be updated together:

- schema and migrations
- ActiveRecord models and helper names
- DAG runtime / maintenance / audit code
- tests and fixtures
- operator/debug/CLI code
- normative docs, design docs, and implementation plans

This cut targets turn-visibility vocabulary only.

It does not automatically rename unrelated anchor usages, such as:

- branch/fork anchors
- generic UI/document prose where "anchor" does not mean "the public node of a turn"

If an active field/message/test name uses `anchor` specifically to mean a turn head, it should be renamed during cleanup even if it sits outside the core rename matrix.

At the schema layer, the cut must include persisted column names plus schema object names that still encode the old vocabulary, including:

- `dag_lanes.next_anchored_seq`
- `dag_turns.anchor_*`
- `dag_turns.anchored_seq`
- partial index definitions on `dag_turns` that reference the renamed columns
- schema object names that still literally contain `anchor` / `anchored_seq`
- `dag_turns` check constraint names that include `anchor` / `anchored_seq`

Because destructive DB refactors are allowed in this repo, the canonical path is:

1. edit the defining migration in place
2. run `bin/rails db:reset`
3. verify the regenerated [`schema.rb`](/Users/jasl/Workspaces/Cybros/cybros/cybros/db/schema.rb) contains no old turn-visibility names

## Non-Goals

- no new DAG entity
- no new node types
- no hierarchical graph model
- no behavior change beyond terminology cleanup and the public-semantics emphasis already approved

## Required Cleanliness Standard

This cut is only acceptable if it is globally clean:

- no leftover public/docs/test references to the old terminology except in historical archive material
- no compatibility aliases in Ruby code
- no mixed `anchor`/`head` vocabulary in active docs
- no mixed `anchored_seq`/`lane_seq` vocabulary in active code

Historical docs under `docs/archive/` may remain untouched unless they are still treated as active.

This rename design/plan pair should be archived after execution, because they intentionally record the pre-cut terminology.

## Recommended Follow-On Order

1. Land the rename cut completely.
2. Update the turn-first hot-path work to use the new terminology from the start.
3. Return to context-budget compaction work after the DAG vocabulary is stable.
