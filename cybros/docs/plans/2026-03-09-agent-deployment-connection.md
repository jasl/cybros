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
- `docs/plans/2026-03-09-programmable-agent-preflight-design.md`
- `docs/product/domain_model.md`
- `docs/product/execution_model.md`
- `docs/product/agent_rpc.md`
- `docs/plans/2026-03-08-phase-1-schema-cut-list.md`

## Implementation Tracks

### 1. Domain And Schema

- keep `AgentProgram` focused on source identity, manifest, and agent-defined config contract
- keep runtime connectivity, inspection, activation, and health on `AgentDeployment`
- do not introduce `agent_hosts` in v1
- add durable `RunDraft` state instead of pushing draft lifecycle into `ConversationRun`
- add durable RPC runtime-state artifacts for sessions, invocations, and callback receipts
- ensure `conversation_runs` snapshot deployment fingerprint, activation epoch, effective public settings, and effective agent config
- keep `automations` bound to `agent_program_id + execution_target_id`

### 2. Run Materialization

- open a mutable `RunDraft` before agent preparation
- allow `turn.prepare` to operate on the draft
- block draft finalization for approval when required
- materialize immutable `ConversationRun` only after finalization
- keep draft-only terminal states off `ConversationRun`

### 3. Deployment Registration

- register deployments explicitly through operator-managed connection details
- support inspection via `initialize`, `agent.describe`, `agent.health`, and `agent.schemas.get`
- treat the execution environment as a fact, not a first-class v1 product model

### 4. Transport

- keep the message protocol transport-neutral
- implement a real network binding first
- keep stdio as a dev/test adapter only
- avoid any design that requires Cybros to hold ambient long-lived agent ownership
- scope each bounded session to one lifecycle request or turn-hook invocation, not one long-lived conversation turn

### 5. End-To-End Coverage

- cover external start of a deployment
- cover explicit deployment registration in Cybros
- cover inspect and healthcheck
- cover selecting the registered deployment
- cover a real turn through `turn.prepare` and `turn.compose`
- cover replay-safe invocation and callback de-duplication
- cover audit snapshotting of resolved deployment facts

## Acceptance

- active product docs all describe the same deployment-centric model
- no active doc assumes `AgentHost` as a v1 canonical model
- `agent_config` remains opaque JSON in v1
- production transport direction is network-first
- draft-time public mutations are staged until finalization
- bounded sessions, logical invocations, and callback receipts are modeled separately
- failure-path coverage exists for session auth, idempotent replay, approval park/resume, and activation drift
- the e2e registration and invocation path is simple enough to implement without architectural workarounds
