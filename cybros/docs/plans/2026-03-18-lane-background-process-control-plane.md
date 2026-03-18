# Lane Background Process Control Plane

## Status

Implemented in the Rails app as a Rails-native control plane plus kernel tools.

This document reflects the shipped code, not the earlier `agents/claw` registry proposal.

## Final Architecture

- `LaneProcess` is the durable, user-visible control-plane record.
- Process lifecycle is managed directly by Rails services:
  - `LaneProcesses::Launcher`
  - `LaneProcesses::Reconciler`
  - `LaneProcesses::Stopper`
  - `LaneProcesses::LogReader`
  - `LaneProcesses::ProcessRuntime`
- Agent-facing process control is exposed as Rails kernel tools:
  - `start_background_process`
  - `list_lane_processes`
  - `read_lane_process_log`
  - `stop_lane_process`
- The conversation UI renders active process state in the existing composer status rail.

There is no separate `agents/claw` in-memory background-process registry in this cut.

## Scope

- A process belongs to one `conversation` and one `DAG::Lane` in that conversation graph.
- Agent tools may only fully manage processes created by the current lane.
- `list_lane_processes` returns conversation-visible summaries, including rows from other lanes, but marks them as non-manageable.
- Users may stop any visible process from the conversation page.

## Persistence Model

`lane_processes` stores:

- `conversation_id`
- `lane_id`
- `owner_turn_id`
- `started_by_type`
- `status`
- `title`
- `command`
- `cwd`
- `pid`
- `pgid`
- `log_path`
- `port_hints`
- `exit_code`
- `started_at`
- `last_seen_at`
- `ended_at`
- `summary_json`

`summary_json` currently stores launch metadata including:

- resolved `cwd`
- startup grace window
- `process_start_signature`

## Process Identity Safety

To reduce PID-reuse risk, Rails captures a process start signature using `ps -o lstart`.

- `Launcher` stores the signature at start time.
- `Reconciler` and `Stopper` compare the current process start signature with the stored one.
- If the PID is alive but the signature no longer matches, the row is downgraded to `lost` and no signal is sent.

This is best-effort safety, not a strong-consistency contract.

## State Model

Statuses:

- `starting`
- `running`
- `failed`
- `exited`
- `killed`
- `lost`

Current transitions:

- `starting -> running` when the process survives the startup grace window
- `starting -> failed` when launch bookkeeping or startup fails
- `starting -> lost` when a stale starting row never received a PID
- `running -> exited` when reconciliation discovers the process is gone
- `running -> killed` when user or lane-authorized agent stop succeeds
- `running -> lost` when identity no longer matches the stored launch signature

## Output Model

- Background processes are non-interactive.
- stdout and stderr are redirected to `.cybros/processes/<lane_process_id>/combined.log` under the lane workspace.
- The UI does not render logs in this cut.
- `read_lane_process_log` is available for backend and agent use.

`LogReader` now tails from the end of the file instead of loading the whole log into memory.

## Port Conflict Handling

`Launcher` performs best-effort preflight before spawning:

1. Reconcile active tracked rows for the conversation.
2. Reject if any active tracked `LaneProcess` already claims an overlapping `port_hints` entry.
3. Reject if an untracked local TCP listener is already bound to one of the requested ports.

This prevents the most common “agent left a server running” and “user manually started the port first” failures.

## UI

Conversation pages render process state above the composer input in the existing status rail.

- `alert-info` for current-lane processes
- `alert-warning` when any active process belongs to another lane
- each item shows:
  - title
  - status
  - lane label
  - port hints
  - `Stop`

The UI intentionally remains minimal:

- no standalone process page
- no log viewer
- no process history browser

## Verification

Verified with:

- focused model, service, tool, and integration tests
- real `bin/dev`
- real database inspection
- real browser interaction against the conversation page

Real-environment acceptance includes:

- starting a branch-lane background process
- confirming the conversation page shows an `alert-warning` item with lane label
- stopping the process from the UI
- confirming the DB row transitions to `killed`
- confirming the PID is no longer alive
- confirming port-conflict preflight rejects an occupied port
