# Cybros Product Docs

This directory is the normative product-definition set for the programmable-agent rebaseline.

Plans under `docs/plans/` may refine implementation details and sequencing, but they do not replace the product docs as the source of truth. If a plan conflicts with a product doc, the product doc wins and the plan must be rewritten.

Historical pre-rebaseline material remains available in git history at commit `84b7e3d`.

## Reading Order

Read the product contract in this order:

1. `vision.md`
2. `architecture.md`
3. `agent_contract.md`
4. `domain_model.md`
5. `state_taxonomy.md`
6. `kernel_service_surface.md`
7. `run_lifecycle.md`
8. `execution_model.md`
9. `automation.md`
10. `runtime_governance.md`
11. `programmable_agents.md`
12. `agent_rpc.md`
13. `nexus_role.md`
14. `roadmap.md`
15. `migration_alignment.md`

Use plan docs only after the contract above is understood.

## Core Invariants

- Cybros is the control plane and the sole system of record.
- External programmable agents are bounded runtimes, not peer control planes.
- The canonical agent loop runs through Cybros for planning, policy, approval, finalization, execution handoff, transcript, and audit.
- `AgentProgram` is the selectable product identity. `AgentDeployment` is the connectable runtime binding.
- `ExecutionTarget` is a first-class product concept: `ExecutionLocation + Workspace`.
- Runtime governance remains split into provider limits, job throughput, and execution capacity.
- Conversations and automations are first-class entrypoints that resolve into the same canonical run lifecycle.
- Draft-time mutations are staged on `RunDraft` and only commit during finalization.
- Each materialized run snapshots one contract, one deployment binding, one target, one permission preset, and one governor snapshot.
- Memory, knowledge, automation, connectors, MCP, and future stable protocol surfaces belong to Cybros substrate, even when external agents also maintain their own off-loop capabilities.
- Off-loop agent elasticity is allowed, but anything that changes Cybros product state or governed execution must pass back through Cybros surfaces.
- Breaking changes are allowed when needed to reach the correct long-term architecture.
