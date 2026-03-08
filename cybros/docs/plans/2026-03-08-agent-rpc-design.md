# Agent RPC Design

Superseded on 2026-03-09.

Do not use this file as an implementation source.

It was written before the deployment-registration rebaseline and therefore mixes together assumptions that are no longer valid in v1:

- stdio as the default production transport
- `AgentHost` as a core domain model
- turn execution without explicit draft-before-run semantics

Use these documents instead:

- `docs/product/agent_rpc.md`
- `docs/plans/2026-03-09-agent-deployment-connection-design.md`
- `docs/plans/2026-03-09-agent-deployment-connection.md`

If the longer historical draft is needed, read it from git history at commit `84b7e3d`.
