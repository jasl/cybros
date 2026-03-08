# Agent Deployment Connection Implementation Plan

## Goal

Implement the approved programmable-agent runtime model around:

- `RunDraft` as the mutable planning object
- immutable `ConversationRun`
- `AgentDeployment` as the only connectable entity in v1
- operator-managed deployment registration
- network transport as the primary production path

## Canonical References

- `docs/plans/2026-03-09-agent-deployment-connection-design.md`
- `docs/product/domain_model.md`
- `docs/product/execution_model.md`
- `docs/product/agent_rpc.md`
- `docs/plans/2026-03-08-phase-1-schema-cut-list.md`

## Implementation Tracks

### 1. Domain And Schema

- keep `AgentProgram` focused on source identity, manifest, and agent-defined config contract
- keep runtime connectivity, inspection, activation, and health on `AgentDeployment`
- do not introduce `agent_hosts` in v1
- ensure `conversation_runs` snapshot deployment fingerprint and effective agent config
- keep `automations` bound to `agent_program_id + execution_target_id`

### 2. Run Materialization

- open a mutable `RunDraft` before agent preparation
- allow `turn.prepare` to operate on the draft
- block draft finalization for approval when required
- materialize immutable `ConversationRun` only after finalization

### 3. Deployment Registration

- register deployments explicitly through operator-managed connection details
- support inspection via `initialize`, `agent.describe`, `agent.health`, and `agent.schemas.get`
- treat the execution environment as a fact, not a first-class v1 product model

### 4. Transport

- keep the message protocol transport-neutral
- implement a real network binding first
- keep stdio as a dev/test adapter only
- avoid any design that requires Cybros to hold ambient long-lived agent ownership

### 5. End-To-End Coverage

- cover external start of a deployment
- cover explicit deployment registration in Cybros
- cover inspect and healthcheck
- cover selecting the registered deployment
- cover a real turn through `turn.prepare` and `turn.compose`
- cover audit snapshotting of resolved deployment facts

## Acceptance

- active product docs all describe the same deployment-centric model
- no active doc assumes `AgentHost` as a v1 canonical model
- `agent_config` remains opaque JSON in v1
- production transport direction is network-first
- the e2e registration and invocation path is simple enough to implement without architectural workarounds
