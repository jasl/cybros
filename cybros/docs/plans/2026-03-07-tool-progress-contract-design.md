# Superseded: Tool Progress Contract Design

This file is retained only as a historical pointer.

It is no longer an active design document and should not be used for implementation planning.

Use these documents instead:

- [2026-03-08-turn-execution-progress-design.md](./2026-03-08-turn-execution-progress-design.md)
- [2026-03-08-turn-execution-progress.md](./2026-03-08-turn-execution-progress.md)

Reason for supersession:

- the narrower `tool progress` framing has been replaced by the broader `turn_execution + activities[]` execution model
- subagents are now modeled as first-class execution activities while remaining independent conversations/graphs
- observability, retention, and debug-mode diagnostics are now part of the canonical execution contract

If historical context is needed, use git history rather than this file.
