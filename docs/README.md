# Docs Index

This directory contains Cybros architecture/design notes intended for humans and LLM agents.

## DAG engine

- Public API boundary: `docs/dag/public_api.md`
- Workflow engine (scheduler/runner/jobs/hooks): `docs/dag/workflow_engine.md`
- Normative behavior spec (nodes/edges/states/invariants/streaming): `docs/dag/behavior_spec.md`
- Sub-agent patterns: `docs/dag/subagent_patterns.md`
- Audit history: `docs/dag/audit.md`

## AgentCore (DAG-first)

- Architecture: `docs/agent_core/architecture.md`
- Behavior spec: `docs/agent_core/behavior_spec.md`
- Public API / injection points: `docs/agent_core/public_api.md`
- Node payload schemas: `docs/agent_core/node_payloads.md`
- Context management + auto-compaction: `docs/agent_core/context_management.md`
- Knowledge / Context / Memory design:
  - Considerations: `docs/agent_core/knowledge_context_memory_considerations.md`
  - Design (Lite vs Ultimate): `docs/agent_core/knowledge_context_memory_design.md`
  - Implementation plan: `docs/agent_core/knowledge_context_memory_implementation_plan.md`
- Security: `docs/agent_core/security.md`
- Migration parity notes: `docs/agent_core/parity.md`

## Execution subsystem (ExecHub + Runner)

- Design (policies, sandboxing, NAT, rollout plan): `docs/execution/execution_subsystem_design.md`
