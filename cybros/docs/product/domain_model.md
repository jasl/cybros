# Domain Model

## Core Entities

### AgentProgram

The stable user-selectable programmable-agent identity.

Owns:

- display identity
- source package or source reference
- stable contract namespace
- operator-managed global config state
- current published contract fingerprint

### Agent Contract Version

The immutable contract artifact a run executes against.

Owns:

- manifest snapshot
- protocol version
- global config schema
- per-conversation config schema
- capability declarations
- one stable contract fingerprint

V1 may persist this as fingerprints and snapshots instead of a dedicated table, but the concept is mandatory.

### AgentDeployment

The registered, reachable runtime binding Cybros invokes for one `AgentProgram`.

Owns:

- transport and endpoint details
- deployment bearer secret reference
- activation state
- health state
- deployment fingerprint or revision
- inspection snapshots

### ExecutionLocation

The operator-managed execution environment.

Examples:

- personal workstation
- remote VM
- hosted sandbox fleet entry

Owns:

- trust boundary metadata
- environment classification
- visibility tags
- base execution-capacity settings

### Workspace

The location-scoped working directory or handle.

Owns:

- `execution_location_id`
- root path or workspace handle
- workspace type
- capability tags
- discovery tags
- availability state

### ExecutionTarget

The reusable runtime handle for `ExecutionLocation + Workspace`.

Owns:

- canonical pairing of location and workspace
- user-facing selection identity
- target-level sandbox posture
- optional execution-capacity overrides
- target-switch policy inputs

### Conversation

The interactive product aggregate.

Owns:

- `agent_program_id`
- `default_execution_target_id`
- `permission_mode`
- public conversation settings
- per-conversation agent config

It does not expose storage-level mutation as product API.

### RunDraft

The durable planning record for one possible execution attempt.

Owns:

- entrypoint and initiating-actor context
- pinned program, contract, deployment, provider, and target candidates
- effective permission preset
- staged public mutations
- prepared plan output
- approval state
- invocation bookkeeping
- expiry and stale-detection state

### ConversationRun

The immutable execution snapshot for one conversation-scoped attempt.

Owns:

- finalized runtime selection
- effective settings and config snapshot
- target snapshot
- deployment and contract snapshot
- governor snapshot
- execution lifecycle timestamps and result state

### ConversationKVEntry

The shared per-conversation working-state entry for agents.

Owns:

- namespaced key
- JSON value
- current-state semantics

It is operational state, not append-only audit history.

### Automation

The definition aggregate for scheduled or event-triggered work.

Owns:

- `agent_program_id`
- `execution_target_id`
- `permission_mode`
- schedule or trigger definition
- task payload

## Agent RPC Runtime State

### AgentRPCSession

The bounded authorization artifact for one invocation attempt.

Owns:

- pinned deployment binding
- scope identity
- session bearer digest
- allowed callback methods
- expiry and session status

### AgentRPCInvocation

The durable logical record for one lifecycle or turn-hook call.

Owns:

- method
- scope identity
- `invocation_id`
- request hash
- result or error snapshot
- replay-safe status

### AgentRPCOperationReceipt

The durable de-duplication record for agent-to-Cybros side effects.

Owns:

- parent invocation identity
- `operation_id`
- effect summary
- replay-safe status

## Ownership Summary

- Users and operators select `AgentProgram`, never `AgentDeployment`.
- `AgentDeployment` is runtime connectivity, not product identity.
- `RunDraft` is mutable planning state.
- `ConversationRun` is the only immutable execution state record.
- `ExecutionLocation`, `Workspace`, and `ExecutionTarget` are Cybros product models, not Nexus-owned abstractions.
- Public settings, per-conversation config, KV, memory, knowledge, and system state remain different storage classes even when the first implementation is simple.
