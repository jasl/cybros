# Runtime Rebaseline Roadmap

## Status

- Current feature work is frozen around the programmable-agent rebaseline.
- Breaking changes are allowed across product models, runtime services, and integration layers.
- The immediate objective is a clean V1 substrate, not compatibility with Phase 0 shapes.

## Phase 0.75: Contract Freeze

Goal: preserve the engine assets that still matter and freeze the new product contract.

Keep as core assets:

- DAG scheduling and execution
- conversation event and streaming semantics
- tool loop and approval flow
- prompt assembly primitives
- subagent primitives
- MCP, memory, and skills integration points

Acceptance:

- normative product docs exist for architecture, contract, lifecycle, automation, and kernel services
- active plans no longer define product semantics by themselves

## Phase 0.9: Ownership Baseline

Goal: eliminate remaining model-ownership ambiguity before implementation.

Deliverables:

- `AgentProgram` as selectable identity
- immutable contract-fingerprint concept between program and deployment
- `AgentDeployment` as reachable binding
- `RunDraft` as durable planning state
- explicit Cybros ownership of `ExecutionLocation`, `Workspace`, and `ExecutionTarget`
- automation as a first-class entrypoint

Acceptance:

- no product doc says `AgentDeployment` is the user-facing selector
- no core lifecycle rule needs to be reconstructed from plan docs

## Phase 0.95: Implementation Preflight

Goal: lock the invariants that must not drift during implementation.

Deliverables:

- staged mutation semantics for `turn.prepare`
- approval park and resume rules
- session scope and deployment identity rules
- replay and idempotency rules
- durable admission and parking rules for runtime governance

Acceptance:

- failure paths are part of plan scope, not postponed as cleanup

## Phase 1: Runtime Kernel Re-baseline

Goal: move from metadata-driven runtime selection to first-class runtime entities.

Deliverables:

- `RunDraft`
- `AgentDeployment`
- agent RPC runtime-state tables
- explicit conversation runtime defaults
- explicit automation runtime defaults
- `ExecutionLocation`, `Workspace`, and `ExecutionTarget`
- provider limiter fields, job settings, and execution-quota fields
- public settings/config/KV surfaces
- immutable run snapshots

Acceptance:

- conversations persist agent, target, and permission defaults as first-class fields
- runs snapshot program, contract, deployment, target, provider, and governors
- automations bind to agent and target primitives
- blocked work parks durably instead of holding worker throughput

## Phase 2: Programmable-Agent Contract And Deployment Lifecycle

Goal: make bounded external runtimes a real product surface.

Deliverables:

- operator-managed deployment registration
- inspection and activation gate
- `agent_rpc` v1 baseline
- network transport plus stdio debug adapter
- published global and per-conversation config schemas
- reference programmable-agent fixture and starter template

Acceptance:

- a healthy deployment can be registered, inspected, activated, and invoked end to end
- Cybros remains authoritative for planning, policy, approvals, and audit

## Phase 3: Automation Runtime

Goal: land the non-interactive execution path as a first-class product capability.

Deliverables:

- durable automation dispatch
- automation-run records
- optional conversation binding
- manual-approval parking semantics when non-default presets require review
- operator-visible automation audit

Acceptance:

- automation uses the same canonical run lifecycle as conversations
- deployment and target are snapshotted per automation run

## Phase 4: Nexus Re-alignment

Goal: re-baseline Nexus and Conduits around execution-only semantics.

Deliverables:

- updated protocol language
- execution-target-aware directive planning
- refined mapping from Conduits concepts to product execution concepts

Acceptance:

- Nexus remains execution-only
- Cybros product models remain canonical

## Phase 5: Product Surfaces

Goal: expose the new runtime model clearly in the product.

Deliverables:

- composer agent selector
- permission preset selector
- execution-target selector
- execution-target and deployment settings surfaces
- run audit views
- automation surfaces
- developer-grade observability

Acceptance:

- users can choose agent, preset, and target per conversation
- operators can manage targets, deployments, automations, and runtime settings through supported surfaces

## Phase 6: Expression Validation

Goal: prove the substrate can express multiple agent product categories.

Validation targets:

- general assistant
- coding agent
- research agent
- trading agent
- chat or roleplay agent

Acceptance:

- at least one working expression per category runs on the canonical substrate
- no category requires a second control plane or an ad hoc run loop

## Deferred Backlog

- plugin marketplace and signing model
- third-party trust distribution
- cross-instance Agent2Agent protocol
- broader channel ecosystem expansion
