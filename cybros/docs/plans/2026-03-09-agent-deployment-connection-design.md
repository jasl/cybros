# Agent Deployment Connection Design

## Goal

Refine the programmable-agent v1 architecture around:

- immutable `ConversationRun` execution units
- explicit pre-run planning via drafts
- `AgentDeployment` as the only connectable entity
- operator-managed deployment registration
- network transport as the real production path
- a realistic E2E flow for start -> register -> inspect -> invoke

Implementation of this design is gated by `docs/plans/2026-03-09-programmable-agent-preflight-design.md` and refined by:

- `docs/plans/2026-03-09-execution-target-discovery-design.md`
- `docs/plans/2026-03-09-permission-presets-design.md`

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

V1 should treat it as durable runtime state rather than an in-memory convenience object.

Whether the storage is implemented as a table or an equivalent durable record, it must survive approval parks, retries, and stale-draft detection.

`turn.prepare` operates on the draft, not on an already-finalized `ConversationRun`.

During that planning session, any reads or mutation intents flow through Cybros public APIs rather than duplicate ad hoc channels on the hook result.

### 3. Approval Blocks Draft Finalization, Not Run Mutation

If the agent proposes a different execution target and policy requires confirmation:

- Cybros blocks the draft
- the current planning session ends cleanly
- no immutable `ConversationRun` is mutated in place
- Cybros persists the prepared draft result before parking
- after approval, Cybros resumes local draft finalization without reopening planning
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
- deployment bearer secret reference
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
- deployment bearer secret reference
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

A lifecycle request or one turn-hook invocation uses one bounded logical session.

That session may be carried by:

- one WebSocket connection
- one stdio adapter process session

But the correctness contract is transport-independent:

- sessions may end on success, failure, or approval park
- resume always uses a new session
- the agent must not rely on transport continuity

Related runtime artifacts should stay distinct:

- bounded session for authorization scope
- durable invocation record for one logical call
- durable operation receipts for de-duplicated callbacks

V1 may keep authentication lightweight:

- Cybros opens the pinned deployment endpoint and presents the deployment bearer secret
- the deployment proves its identity by successfully answering `initialize` on that pinned endpoint with matching deployment identity claims
- one short-lived session bearer then authorizes callbacks for one invocation scope

This is enough for trusted self-hosted deployments and does not require mTLS or signature choreography in v1.

### 9. Activation Is A Simple Gate, Not A Compatibility Layer

V1 does not need a compatibility matrix between program and deployment revisions.

Activation should stay simple:

- exact supported `protocol_version`
- required methods present
- inspection succeeds
- healthcheck is healthy at activation time

Cybros may persist metadata and inspection snapshots for debugging, but it should not build fallback or compatibility-routing behavior around them.

### 10. `agent_config` Is Opaque JSON In V1

Cybros stores and audits `agent_config`, but does not strongly validate it against agent-defined schemas in v1.

Cybros is responsible for:

- valid JSON shape
- size and storage limits
- audit trail

The agent is responsible for interpreting it correctly.

Shared and cross-agent operational state belongs in conversation KV, not `agent_config`.

Canonical contract ownership stays on `AgentProgram`.

`AgentDeployment` may cache inspected schema snapshots for debugging and audit, but it does not replace the program contract as the source of truth.

### 11. Execution Target Discovery Is A Read-Side Public API

Programmable agents should not guess target ids from prompt context alone.

V1 should expose formal read-side target discovery through Cybros public APIs:

- `execution_target.list`
- `execution_target.get`

Those methods return visible target summaries for the current draft scope.

They are not the same thing as a target-switch request.

### 12. Permission Presets Are Conversation- And Automation-Scoped Runtime Inputs

Programmable-agent turns should not inherit their approval behavior only from resolver defaults.

V1 should treat permission presets as explicit product-level runtime inputs:

- `Conversation.permission_mode`
- `Automation.permission_mode`

Those presets compile into Cybros-owned runtime policy bundles and are then snapshotted on drafts and runs.

This keeps the composer permissions control, automation defaults, tool policy, and target-switch behavior aligned under one durable runtime model.

### 13. Target Switch Policy Reuses `allow` / `confirm` / `deny`

Target switching should reuse the same decision vocabulary already used by Cybros policy infrastructure.

Default behavior:

- same target: `allow`
- different visible target: `confirm`
- invisible, inactive, unhealthy, or forbidden target: `deny`

Policy may grant auto-switch inside trusted boundaries, but that override is owned by Cybros policy, not by prompt conventions.

### 14. Interactive Conversation Defaults Use Canonical Conversation Fields

The conversation footer should expose both:

- an agent selector
- a permission preset selector
- a target selector

For the agent selector, the canonical persisted state is:

- `Conversation.agent_program_id`

That field changes when:

- the user switches the agent in the composer footer

Changing the conversation agent affects future drafts and runs only.

It does not retroactively change:

- the currently running turn
- an already parked draft
- subagents launched by the currently selected top-level agent

`subagent` behavior remains owned by the active top-level programmable agent for that turn and does not inherit future conversation-level agent selector changes.

If the selected `AgentProgram` has no active healthy deployment, the composer should surface an explicit stale warning and Cybros should refuse to materialize a new draft until the operator fixes or the user reselects the conversation agent.

For the target selector, the canonical persisted state is:

- `Conversation.default_execution_target_id`

That field changes when:

- the user switches the target in the composer footer
- an accepted `execution_target.propose` finalizes successfully

There is no separate per-message target override surface in v1.

`agent_config` should remain conversation-scoped storage, but it should be treated as a namespaced store keyed by a stable selected-`AgentProgram` contract namespace. Switching the conversation agent should not clear unrelated namespaces.

### 15. Targets And Deployments Need Settings Surfaces

Programmable-agent deployment and routing features are not operator-usable if they can only be reached through agent callbacks or internal tables.

V1 should therefore include settings surfaces for:

- execution-target management
- agent-deployment registration, inspection, activation, and health visibility

These surfaces should be treated as first-class implementation scope, not deferred polish.

### 16. Automation Resolves Deployment At Execution Time

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
4. during the bounded planning session, the agent may read approved state, inspect visible execution targets, and request staged public-state mutations or execution-target proposals through Cybros public APIs
5. Cybros calls `turn.prepare`
6. the agent returns prompt fragments and workflow decisions
7. policy resolves the draft
8. if approval is required, Cybros persists the prepared draft result and draft finalization pauses
9. once final, Cybros atomically commits staged draft state, materializes immutable `ConversationRun`, snapshots final inputs, and durably hands the run off for execution
10. Cybros queues and executes the run
11. Cybros calls `turn.compose` and later `turn.handle_error` as needed

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
5. persist normalized inspection results and debug metadata
6. activate the deployment only if the v1 protocol version matches exactly, the required methods are present, and health is green

## E2E Acceptance Path

The first realistic E2E path should prove:

1. a reachable deployment is started outside the web app
2. the operator registers it in Cybros
3. Cybros inspects and healthchecks it
4. a conversation selects the corresponding `AgentProgram`
5. an operator can manage the relevant execution target and deployment through settings surfaces
6. a conversation selects the corresponding `AgentProgram` and default execution target through first-class UI controls
7. a real run is planned through a draft
8. the agent can inspect visible execution targets through the public API boundary
9. a target switch defaults to `confirm` unless effective policy allows auto-switch
10. an approval-required draft resumes finalization without a second planning call
11. the run materializes into immutable `ConversationRun`
12. the deployment is invoked over the real transport using deployment and session bearers
13. the resulting run audit shows:
   - resolved deployment
   - deployment fingerprint
   - deployment activation epoch
   - execution target
   - effective public settings
   - effective `agent_config`
   - provider and governor facts

If this E2E path becomes twisted or requires hidden side channels, the product model should be reconsidered before implementation continues.
