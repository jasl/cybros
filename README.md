# Cybros

Cybros is an experimental AI Agent platform that models conversations as dynamic Directed Acyclic Graphs (DAGs).

## Quick Start

```bash
bin/setup
bin/dev
```

Open http://localhost:3000

## Testing

```bash
bin/rails test
bin/ci
```

## DAG Engine Notes

- Core DAG models live under `app/models/dag/*`.
- App-safe primitives are `DAG::Lane` + `DAG::Turn`:
  - Each node belongs to exactly one lane (`dag_nodes.lane_id`).
  - `fork` creates a new `branch` lane + the first root node for that lane.
  - `merge` creates a pending join `agent_message` node in the target lane (source lanes are not auto-archived).
  - Turns are ordered within a lane via `dag_turns.anchored_seq`.

Design/spec docs:

- `docs/dag_workflow_engine.md`
- `docs/dag_behavior_spec.md`

## Multi-DB + Jobs (Solid Queue)

Development uses Solid Queue (`config/environments/development.rb`), backed by the `queue` database.

If you see errors like `relation "solid_queue_jobs" does not exist`, install/migrate Solid Queue:

```bash
bin/rails solid_queue:install
bin/rails db:migrate:queue
```
