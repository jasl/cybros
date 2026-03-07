# Superseded: Tool Progress Contract Implementation Plan

This file is retained only as a historical pointer.

It is no longer an active implementation plan and should not be executed.

Use these documents instead:

- [2026-03-08-turn-execution-progress-design.md](./2026-03-08-turn-execution-progress-design.md)
- [2026-03-08-turn-execution-progress.md](./2026-03-08-turn-execution-progress.md)

Reason for supersession:

- the implementation target is now `turn_execution + activities[]`, not a tool-only `run_state.tools[]` contract
- observability, debug-mode diagnostics, retention, and failure-injection coverage are first-class parts of the execution plan
- subagent support is integrated into the same execution model rather than deferred as an awkward add-on

If historical context is needed, use git history rather than this file.
