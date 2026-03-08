# Cybros Product Docs

This directory is the active product-definition set for the runtime rebaseline approved on 2026-03-08.

The old pre-rebaseline product docs were removed from the working tree after archival cleanup.

If historical context is needed, read them from git history at commit `84b7e3d`.

Use the documents in this directory as the normative product source of truth.

The linked plan documents in the reading order below refine runtime invariants and implementation-facing semantics; they do not replace the product docs as the normative product model.

## Reading Order

1. `vision.md`
2. `architecture.md`
3. `domain_model.md`
4. `state_taxonomy.md`
5. `execution_model.md`
6. `runtime_governance.md`
7. `programmable_agents.md`
8. `agent_rpc.md`
9. `../plans/2026-03-09-execution-target-discovery-design.md`
10. `../plans/2026-03-09-permission-presets-design.md`
11. `../plans/2026-03-09-programmable-agent-preflight-design.md`
12. `nexus_role.md`
13. `roadmap.md`
14. `migration_alignment.md`

## Current Rules

- Cybros is an agent runtime kernel and control plane.
- Programmable agents are trusted, self-hosted, out-of-process programs.
- Nexus is an execution substrate, not a programmable-agent runtime.
- `ExecutionTarget` is a first-class concept: `location + workspace`.
- Runtime governance is split into provider-credential limits, job concurrency, and execution quotas.
- Conversations are programmable through public APIs, not storage-level writes.
- Conversation-level runtime defaults include top-level agent selection, permission preset, and execution target selection.
- Conversation and automation permission presets compile into explicit runtime policy bundles.
- Execution-target discovery and target-switch policy are separate concerns.
- Draft-time public mutations are staged until draft finalization or rejected entirely.
- Each run pins one deployment binding and runtime-governor snapshot for execution.
- `agent_rpc` is the language-agnostic contract between Cybros and programmable agents.
- Breaking changes are allowed when needed to reach the correct long-term architecture.
