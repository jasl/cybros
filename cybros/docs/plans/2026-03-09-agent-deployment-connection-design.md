# Agent Deployment Connection Design

## Goal

Refine the programmable-agent v1 architecture around:

- immutable `ConversationRun` execution units
- explicit pre-run planning via drafts
- `AgentDeployment` as the only connectable entity
- operator-managed deployment registration
- network transport as the real production path
- a realistic E2E flow for start -> register -> inspect -> invoke

## Problem Statement

The 2026-03-08 rebaseline clarified the runtime split, but two parts remained underdefined:

- how a run is planned before an immutable `ConversationRun` exists
- how Cybros connects to a real deployment without turning `AgentHost` into a second control plane

Without a tighter definition, the product drifts in two bad directions:

- `ConversationRun` becomes both a mutable plan and an immutable audit record
- `AgentHost` becomes an accidental product model with missing registration, discovery, and operations semantics

## Core Decisions

### 1. `ConversationRun` Is An Immutable Execution Unit

`ConversationRun` is the durable unit that tracks one concrete prompt execution attempt.

It is not the planning object.

V1 should treat it as immutable after materialization and queueing.

Its snapshot records what was actually executed, not what was tentatively proposed earlier.

### 2. Pre-Run Planning Happens In A Draft

Before a `ConversationRun` exists, Cybros opens a mutable run-planning object.

This document calls it `RunDraft`.

The exact implementation may be:

- a service object
- a serialized runtime structure
- a first-class model later

V1 does not require a dedicated table immediately, but it does require a separate semantic layer.

`turn.prepare` operates on the draft, not on an already-finalized `ConversationRun`.

### 3. Approval Blocks Draft Finalization, Not Run Mutation

If the agent proposes a different execution target and policy requires confirmation:

- Cybros blocks the draft
- the current planning session ends cleanly
- no immutable `ConversationRun` is mutated in place
- after approval, Cybros resumes draft finalization
- only then does it materialize the immutable `ConversationRun`

This removes the earlier conflict between approval waits and queue-time snapshot freezing.

### 4. `AgentProgram` And `AgentDeployment` Have Different Jobs

`AgentProgram` is the logical identity of the agent program.

It owns:

- source location
- display identity
- manifest snapshot
- agent-defined config contract

`AgentDeployment` is the connectable binding that Cybros can invoke.

It owns:

- transport kind
- endpoint or local invocation config
- auth or secret reference
- activation state
- health state
- capability and schema discovery snapshots
- resolved revision or fingerprint

Semantically:

- one `AgentProgram` may have many `AgentDeployment`s

V1 product constraint:

- one `AgentProgram` has one active `AgentDeployment`

### 5. `AgentHost` Is Not A V1 Canonical Product Model

The environment that runs the deployment may be:

- a bare-metal machine
- a Docker container
- a workspace-reachable service started by another agent
- any other Cybros-reachable runtime environment

That environment is a deployment fact, not a first-class Cybros product model in v1.

If another agent can reach that environment through normal execution capabilities, it may start or repair a deployment there.

Cybros still only registers and invokes the resulting `AgentDeployment`.

### 6. Registration Is Explicit And Operator-Managed

V1 registration is not auto-discovery and not agent-initiated self-registration.

The intended flow is:

1. the deployment is started somewhere reachable
2. an operator, or another agent acting through normal product surfaces, supplies deployment connection details to Cybros
3. Cybros registers the `AgentDeployment`
4. Cybros runs inspection and health flows through `agent_rpc`

Registration inputs should include at least:

- `agent_program`
- `transport_kind`
- endpoint or local invocation details
- auth reference
- activation state

### 7. Transport Is Neutral, But Network Is The Real V1 Path

`agent_rpc` remains transport-neutral at the message level.

Required v1 bindings:

- primary: network transport for real deployments
- optional adapter: stdio for local development, testing, and debugging

The recommended first network binding is WebSocket.

Reason:

- it supports bounded bidirectional sessions cleanly
- it matches the need for remote containerized deployments
- it avoids making stdio the accidental architecture contract

### 8. Sessions Are Logical, Not Transport-Specific

A lifecycle action or one turn uses one bounded logical session.

That session may be carried by:

- one WebSocket connection
- one stdio adapter process session

But the correctness contract is transport-independent:

- sessions may end on success, failure, or approval park
- resume always uses a new session
- the agent must not rely on transport continuity

### 9. `agent_config` Is Opaque JSON In V1

Cybros stores and audits `agent_config`, but does not strongly validate it against agent-defined schemas in v1.

Cybros is responsible for:

- valid JSON shape
- size and storage limits
- audit trail

The agent is responsible for interpreting it correctly.

Shared and cross-agent operational state belongs in conversation KV, not `agent_config`.

### 10. Automation Resolves Deployment At Execution Time

Automation binds to:

- `agent_program`
- `execution_target`

It does not pin a deployment version in advance.

At execution time, each automation run resolves the currently active deployment and snapshots:

- resolved deployment id
- revision or fingerprint
- transport binding facts

This matches the self-evolution agent model while preserving auditability.

## Run Lifecycle

The intended v1 lifecycle is:

1. execution intent is triggered
2. Cybros opens a `RunDraft`
3. Cybros resolves defaults:
   - `agent_program`
   - current active `AgentDeployment`
   - `execution_target`
   - provider credential
   - runtime governors
4. Cybros calls `turn.prepare`
5. the agent may:
   - return prompt fragments
   - mutate public state
   - propose a different execution target
6. policy resolves the draft
7. if approval is required, draft finalization pauses
8. once final, Cybros materializes immutable `ConversationRun`
9. Cybros queues and executes the run
10. Cybros calls `turn.compose` and later `turn.handle_error` as needed

## Registration And Inspection Flow

The intended v1 deployment flow is:

1. register `AgentProgram`
2. start deployment outside Cybros or through a normal execution path
3. create `AgentDeployment` in Cybros with explicit connection settings
4. run:
   - `initialize`
   - `agent.describe`
   - `agent.health`
   - `agent.schemas.get`
5. persist normalized inspection results
6. activate the deployment for runtime selection

## E2E Acceptance Path

The first realistic E2E path should prove:

1. a reachable deployment is started outside the web app
2. the operator registers it in Cybros
3. Cybros inspects and healthchecks it
4. a conversation selects the corresponding `AgentProgram`
5. a real run is planned through a draft
6. the run materializes into immutable `ConversationRun`
7. the deployment is invoked over the real transport
8. the resulting run audit shows:
   - resolved deployment
   - deployment fingerprint
   - execution target
   - provider and governor facts

If this E2E path becomes twisted or requires hidden side channels, the product model should be reconsidered before implementation continues.
