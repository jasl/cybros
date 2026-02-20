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
- Branch partitioning is modeled via `DAG::Subgraph`:
  - Each node belongs to exactly one subgraph (`dag_nodes.subgraph_id`).
  - `fork` creates a new `branch` subgraph + the first root node for that subgraph.
  - `merge` creates a pending join `agent_message` node in the target subgraph (source subgraphs are not auto-archived).

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
