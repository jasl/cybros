# Runtime Rebaseline Roadmap

## Status

- Current feature work is frozen.
- Existing product docs before this rebaseline remain available in git history at commit `84b7e3d`.
- Breaking changes are allowed across the DAG engine, product models, and integration layers.

## Phase 0.75: Contract Freeze

Goal: freeze and preserve the parts of the current system that are still valid as runtime-kernel assets.

Keep as core assets:

- DAG scheduling and execution model
- conversation event envelope and streaming semantics
- tool loop and approval flow
- subagent primitives
- prompt section assembly
- memory, MCP, and skills integration points

Acceptance:

- old product docs archived
- new normative docs published
- runtime-kernel invariants explicitly documented

## Phase 0.9: Ownership Baseline

Goal: fix the remaining model-ownership gaps before schema and protocol work starts.

Deliverables:

- `AgentDeployment`
- explicit `AgentDeployment` connection and registration rules
- `RunDraft` semantics for pre-run planning
- explicit ownership of `ExecutionLocation`, `Workspace`, and `ExecutionTarget` by Cybros
- explicit target-switch confirm behavior
- execution-target discovery through formal public APIs

Acceptance:

- the deployment unit between program and reachable runtime environment is documented
- the connectable deployment model is documented
- Cybros product models are the canonical source for execution-target semantics
- target-switch confirmation semantics are blocking and auditable
- execution-target discovery is documented separately from target-switch mutation semantics

## Phase 0.95: Implementation Preflight

Goal: lock the runtime invariants that must not drift during Phase 1 and Phase 2 implementation.

Deliverables:

- draft-stage mutation semantics for `turn.prepare`
- deployment identity and session-scope rules
- invocation idempotency and resume rules
- deployment pinning and activation-drift rules
- durable admission and parking semantics for runtime governance

Acceptance:

- the preflight invariants are documented
- active product docs reflect the same invariants
- active implementation plans no longer point at superseded design sources

## Phase 1: Runtime Kernel Re-baseline

Goal: move the product model from metadata-driven conversations to first-class runtime entities.

Deliverables:

- `AgentDeployment`
- `AgentProgram` manifest snapshot, stable config namespace, and config-contract storage
- `ExecutionLocation`
- `Workspace`
- `ExecutionTarget`
- `RunDraft`
- agent RPC session/invocation/operation runtime state
- provider-credential limiter fields
- job-throughput settings
- execution-quota fields
- provider budget reservation and execution capacity lease primitives
- `Conversation` default agent program relation
- `Conversation` default execution target relation
- `Conversation` permission-mode preset
- `Conversation` public settings store
- `ConversationKV`
- `ConversationRun` execution snapshot
- `ConversationRun` materialization contract
- bootstrap default runtime bindings for fresh and reset environments
- public conversation settings mutation surface
- public agent-config mutation surface
- automation target binding in the domain model
- automation permission-mode preset with `full_access` default
- automation domain model without requiring full UI

Acceptance:

- a conversation can be created with an explicit agent program and execution target
- a conversation can persist top-level agent selection, permission preset, and execution target as runtime defaults for future turns
- a run records the actual target, deployment, and agent snapshot it used
- a run is materialized only after draft finalization and then remains immutable
- the schema cut lands as a destructive reset with regenerated first-cut migrations and no legacy compatibility columns kept for the old runtime model
- freshly reset environments bootstrap a usable default agent deployment, execution target, and runtime settings before conversation creation flips to first-class relations
- `ConversationRun` snapshot data is versioned and remains immutable across approval, resume, retry, and completion flows
- agent-config has an explicit public mutation surface and audit trail before programmable-agent schema validation is tightened in later phases
- conversation agent-config remains namespaced across top-level agent switches instead of being cleared wholesale
- agent-visible conversation KV exists as current-state operational storage
- replay-safe session, invocation, and callback de-duplication state exists for `agent_rpc`
- automation records can bind to agent and execution target primitives
- conversation and automation permission presets compile into durable runtime policy bundles and are snapshotted per run
- provider credentials can carry independent runtime limiter fields
- execution locations and targets can carry explicit execution-quota fields
- job throughput is operator-tunable through system settings

## Phase 2: Programmable Agent Deployment + Contract

Goal: define and implement the trusted programmable-agent model.

Deliverables:

- operator-managed deployment registration
- `agent_rpc` v1 baseline
- network transport binding
- stdio debug adapter
- agent manifest inspection flow
- deployment inspection and healthcheck lifecycle
- global config schema publication over the programmable-agent contract
- per-conversation config schema publication over the programmable-agent contract
- Ruby reference implementation
- bundled default template agent

Acceptance:

- a reachable deployment can be registered, inspected, and activated in the UI
- a conversation can then select the corresponding agent program and resolve that active deployment at run time
- deployment health failures and connectivity failures are visible and recoverable
- a Ruby agent can drive a real conversation turn end-to-end through `turn.prepare` and `turn.compose` while the kernel remains authoritative for final prompt assembly, policy, approvals, and run audit
- integration, reference-agent, and Playwright coverage prove external start -> registration -> inspection -> invocation works through the public API boundary

## Phase 3: Nexus Re-alignment

Goal: realign Nexus and Conduits to the execution-only role.

Deliverables:

- updated Conduits semantics
- refined mapping from territory/facility/directive to execution concepts
- execution-target-aware directive planning
- updated protocol docs and Mothership parity path

Acceptance:

- Cybros can target a specific location and workspace for execution
- Nexus does not need to host programmable agents
- the protocol language reflects execution-only semantics

## Phase 4: Product Surfaces

Goal: expose the new model in the product.

Deliverables:

- agent picker
- permission preset picker
- execution target picker
- execution target management settings
- agent deployment management settings
- run audit view
- conversation settings controls
- automation target binding
- developer-grade runtime observability
- developer-grade agent-work and deployment-work views

Acceptance:

- the user can choose an agent, permission preset, and target per conversation
- operators can manage execution targets and agent deployments through settings surfaces
- the agent can discover visible targets and propose target changes through managed APIs
- run history clearly shows what happened and where
- runtime views expose limiter and quota pressure clearly enough for operators

## Phase 5: Demo Agents

Goal: validate that the platform abstractions cover multiple agent forms.

Initial targets:

- coding
- research
- trading
- chat/roleplay

Acceptance:

- at least one real demo per category can run on the new programmable-agent contract
- demo agents validate the execution-target model and conversation control APIs

## Deferred Backlog

These remain intentionally deferred:

- plugin system
- sharing and marketplace
- third-party trust and signing model
- channel ecosystem expansion
- cross-instance agent-to-agent protocols
