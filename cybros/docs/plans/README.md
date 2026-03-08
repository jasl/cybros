# Plans

This directory is reserved for the current active refactor and implementation thread.

As of 2026-03-09, the active implementation sources are:

- `2026-03-08-phase-1-schema-cut-list.md`
- `2026-03-08-runtime-governance-design.md`
- `2026-03-08-runtime-governance.md`
- `2026-03-09-execution-target-discovery-design.md`
- `2026-03-09-permission-presets-design.md`
- `2026-03-09-agent-deployment-connection-design.md`
- `2026-03-09-agent-deployment-connection.md`
- `2026-03-09-programmable-agent-preflight-design.md`

Canonical implementation order for the current programmable-agent rebaseline:

1. `2026-03-09-programmable-agent-preflight-design.md` defines the invariants that later tasks must not violate.
2. `2026-03-08-phase-1-schema-cut-list.md` defines the destructive schema and model cut.
3. `2026-03-09-execution-target-discovery-design.md` defines target discovery, target-switch policy reuse, and confirm-by-default target-switch semantics.
4. `2026-03-09-permission-presets-design.md` defines the conversation-scoped and automation-scoped permission presets, their UI surface, and their compilation into runtime policy bundles.
5. `2026-03-09-agent-deployment-connection-design.md` defines deployment, draft, approval, session, target-switch lifecycle semantics, and the canonical conversation-level agent/target defaults.
6. `2026-03-08-runtime-governance-design.md` defines governor and durable-wait semantics.
7. `2026-03-09-agent-deployment-connection.md` is the executable implementation plan for deployment, conversation runtime selectors, permission presets, target discovery, draft finalization, RPC auth, and E2E coverage.
8. `2026-03-08-runtime-governance.md` is the executable implementation plan for provider limits, job throughput, execution quotas, and observability.

Recommended execution sequencing for an end-to-end automated implementation run:

1. `2026-03-08-runtime-governance.md` Task 1 through Task 3
2. `2026-03-09-agent-deployment-connection.md` Task 1 through Task 3
3. `2026-03-08-runtime-governance.md` Task 4
4. `2026-03-08-runtime-governance.md` Task 7
5. `2026-03-09-agent-deployment-connection.md` Task 4 through Task 8
6. `2026-03-08-runtime-governance.md` Task 5, Task 6, and Task 8

This ordering keeps schema ownership and runtime-resolution dependencies linear enough to execute without manual backtracking.

The two executable plans in this directory are expected to stay automation-ready: every behavior-changing task should name concrete unit, integration, or E2E verification files plus the exact commands needed to fail first and pass after implementation.

For repository-level cutover order around controllers, migrations, and UI updates, also read `docs/product/migration_alignment.md` before implementation starts.

Superseded drafts for this refactor have been moved out of `docs/plans/` and into `docs/archive/plans/2026-03/`.

Historical or unrelated plans have also been moved to `docs/archive/plans/`.
