# Lane Background Process Control Plane Design

## Status

Implemented design for the current Rails-native background process control plane.

This supersedes the earlier draft that assumed a dedicated `agents/claw` runtime registry and `runtime_session_id`.

## Design Goals

- make agent-started service processes visible to users
- let users stop leftover processes from the conversation page
- keep tracking lightweight and best-effort
- avoid resurrection semantics
- avoid live PTY or stdin session management
- keep logs on disk for later inspection

## Chosen Shape

The shipped design uses two layers inside the Rails app:

1. `LaneProcess` as the user-visible control-plane record
2. lightweight Rails services that spawn, reconcile, inspect, and stop OS processes

The agent sees the feature through Rails kernel tools, not through a separate long-lived runtime process manager.

## Lane Ownership

Each row belongs to:

- one `conversation`
- one `DAG::Lane` in that conversation's root graph

Management rules:

- the current lane may start processes for itself
- the current lane may read logs and stop only its own rows
- agents may still list other-lane rows as summaries
- users may stop any visible row from the conversation UI

This gives lane ownership without forcing a separate service registry.

## Process Lifecycle

### Launch

`LaneProcesses::Launcher`:

- validates command and cwd
- materializes the lane workspace directory
- performs port-conflict preflight
- creates a `LaneProcess` row in `starting`
- spawns `/bin/sh -lc <command>` with stdout/stderr redirected to `combined.log`
- records `pid`, `pgid`, and a `process_start_signature`
- upgrades the row to `running` after the startup grace window

If launch bookkeeping fails after `spawn`, Launcher performs best-effort process cleanup and reaping before marking the row `failed`.

### Reconcile

`LaneProcesses::Reconciler` runs on demand:

- active page loads
- composer status refresh
- `list_lane_processes`
- launch preflight

Rules:

- missing PID on a stale `starting` row -> `lost`
- dead process with matching recorded identity -> `exited`
- live process with mismatched start signature -> `lost`
- live process with matching identity -> refresh `last_seen_at`

### Stop

`LaneProcesses::Stopper`:

- refuses to signal when identity mismatches
- marks already-dead rows as `exited`
- sends `TERM`, then `KILL`, to the process group
- marks the row `killed` only after the process is confirmed gone

## Identity Strategy

Pure PID tracking is too weak because PID reuse can target the wrong process.

The current design stores a best-effort start signature:

- source: `ps -o lstart`
- persistence: `summary_json["process_start_signature"]`
- use: stop and reconcile paths must see the same signature before treating the PID as the original process

This is intentionally lightweight and Unix-oriented. It is a best-effort guard, not a portable process identity layer.

## Port Conflict Strategy

`port_hints` are optional but meaningful.

Before spawn:

- reconcile tracked active rows
- reject overlapping tracked ports
- reject locally bound untracked ports

The current implementation detects untracked conflicts by attempting a loopback TCP bind.

## Log Strategy

- one combined log file per `LaneProcess`
- lane-local path under `.cybros/processes/<lane_process_id>/combined.log`
- no streaming UI
- no in-memory stdout transcript buffer

`LaneProcesses::LogReader` reads from the end of the file so very large logs do not require `File.readlines`.

## UI Strategy

The UI stays intentionally small:

- render in the existing composer status rail
- show only active rows
- warning tone when another lane owns the process
- allow user stop directly from the alert

This is enough to solve the port-conflict and leftover-service visibility problem without introducing a new process-management screen.

## Non-Goals

- no PTY semantics
- no stdin interaction
- no resurrection after app restart
- no dedicated process history UI
- no workspace-global registry
- no `agents/claw` background-process subsystem in this cut
