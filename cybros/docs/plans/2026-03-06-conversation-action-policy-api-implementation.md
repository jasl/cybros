# Conversation Action Policy API Implementation

## Summary

This note records the implementation shape of the Conversation Action Policy API introduced for the app-facing chat projection.

Goals:

- Expose a backend-owned action dictionary for current Web UI and future separated clients.
- Keep `NodeBody` responsible for type-level support.
- Keep `DAG::Node#can_*?` responsible for low-level mutation preconditions.
- Move app/UI action availability to a single app-layer policy object.

## Implemented shape

- Policy builder: `Conversation::NodeActionPolicy`
- Projection field: `message["action_policy"]`
- Structure:
  - `actions`
    - `retry`
    - `regenerate`
    - `swipe`
    - `branch`
    - `delete`
    - `restore`
    - `exclude`
    - `include`
    - `translate`
    - `stop`
    - `edit`
  - `capabilities`
    - `execute`

Each action entry is a string-keyed hash with:

- `supported`
- `available`
- optional `mode`
- optional `reason`

## Key semantics

- `retry` and `regenerate` are distinct:
  - `retry` is for `errored` / `stopped` assistant nodes
  - `regenerate` is for completed assistant versions
- `regenerate.mode`
  - `in_place` for current tail assistant reruns
  - `branch` for non-tail assistant regenerate flows
- `delete.mode`
  - `immediate` when strict visibility mutation can happen now
  - `deferred` when the app must request a deferred visibility patch

## Projection and UI

- `Conversation` now decorates its app-facing message reads with `action_policy`.
- Message partials serialize the policy into DOM data attributes.
- Stimulus controllers consume the projected policy instead of inferring availability from local `state` / tail heuristics.
- When tail changes, the client refreshes old/new tail message partials so policy stays current without reintroducing local action gating.

## Run lifecycle sync

- `ConversationRunTracker` now updates `ConversationRun` records from `DAG::Runner`.
- Success and error paths no longer leave `conversation_runs.state = queued` after the node has already reached a terminal state.

## Known follow-ups

- `Conversation#decorate_messages` currently computes `action_policy` per projected message with several graph lookups. This is acceptable for the current pass, but long conversations will likely need batched/cached policy decoration to avoid avoidable hot-path query growth on `show`, pagination, and message refresh.
