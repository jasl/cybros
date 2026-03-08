# Runtime Rebaseline Design

Superseded on 2026-03-09.

Do not use this file as the current architecture reference.

It predates the approved rebaseline where:

- `AgentDeployment` is the only connectable entity in v1
- `ConversationRun` is materialized only after draft finalization
- deployment registration is explicit and operator-managed
- network transport is the real production path

Use these documents instead:

- `docs/product/architecture.md`
- `docs/product/domain_model.md`
- `docs/product/execution_model.md`
- `docs/plans/2026-03-09-agent-deployment-connection-design.md`

Historical context remains available in git history at commit `84b7e3d`.
