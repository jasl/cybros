# Docs Index

This directory contains Cybros architecture/design notes intended for humans and LLM agents.

## DAG engine

- Public API boundary: `docs/dag/public_api.md`
- Workflow engine (scheduler/runner/jobs/hooks): `docs/dag/workflow_engine.md`
- Normative behavior spec (nodes/edges/states/invariants/streaming): `docs/dag/behavior_spec.md`
- Sub-agent patterns: `docs/dag/subagent_patterns.md`
- Historical DAG audit report: `docs/reports/2026-02-19-dag-engine-audit.md`
- Errors: `docs/dag/errors.md`

## AgentCore (DAG-first)

- Architecture: `docs/agent_core/architecture.md`
- Behavior spec: `docs/agent_core/behavior_spec.md`
- Public API / injection points: `docs/agent_core/public_api.md`
- Node payload schemas: `docs/agent_core/node_payloads.md`
- Context management + prompt-working-set / budget behavior: `docs/agent_core/context_management.md`
- Errors: `docs/agent_core/errors.md`
- Historical Knowledge / Context / Memory notes: `docs/archive/agent_core/`
- Security: `docs/agent_core/security.md`
- Migration parity notes: `docs/agent_core/parity.md`

## Execution subsystem (ExecHub + Runner)

- Design (policies, sandboxing, NAT, rollout plan): `docs/execution/execution_subsystem_design.md`
