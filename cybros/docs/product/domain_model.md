# Domain Model

## Core Entities

### AgentProgram

A registered programmable agent package.

Expected responsibilities:

- source location and revision
- manifest snapshot
- global config contract
- per-conversation config contract
- agent-defined configuration semantics

### AgentDeployment

The registered, connectable deployment binding Cybros can invoke for an `AgentProgram`.

Expected responsibilities:

- transport kind
- endpoint or local invocation config
- auth or secret reference
- resolved revision or fingerprint
- health status
- capability and schema discovery snapshots
- deployment-local runtime metadata
- activation state

V1 recommendation:

- one `AgentProgram` has one active `AgentDeployment`
- registration is explicit and operator-managed
- the environment that runs the deployment is not a separate canonical product model in v1

### ExecutionLocation

A Nexus-managed execution environment.

Examples:

- personal mac
- home workstation
- cloud VM

### Workspace

A working directory under an execution location.

Expected responsibilities:

- root path or handle
- workspace type
- capability tags
- availability state

### ExecutionTarget

Logical pair of:

- `execution_location`
- `workspace`

This is the thing a run actually uses.

V1 invariant:

- the selected `workspace` must belong to the selected `execution_location`

### Conversation

The user-facing 1:1 chat/session aggregate.

V1 requirements:

- belongs to user
- has a default `agent_program`
- has a default `execution_target`
- exposes public settings for user and agent mutation
- exposes a public per-conversation agent-config surface
- does not expose storage-level mutation

V1 recommendation:

- conversation selects an `agent_program`
- the runnable deployment is resolved from that program's active deployment

### RunDraft

A mutable planning object used to assemble one concrete `ConversationRun`.

Expected responsibilities:

- proposed execution target
- resolved active deployment
- provisional prompt inputs
- policy and approval decisions before queueing

V1 rule:

- `turn.prepare` operates on the draft
- approval may block draft finalization
- draft finalization materializes immutable `ConversationRun`

### ConversationRun

Tracks one execution attempt and snapshots the context it ran under.

V1 snapshot fields should include:

- snapshot version
- agent program id
- agent deployment id
- deployment revision or fingerprint
- provider credential id
- execution target
- model selection
- effective public settings and `agent_config`
- capability/policy profile
- resolved runtime governor snapshot
- queued/started/finished state

V1 rule:

- the run is materialized only after draft finalization
- the run snapshot is finalized when the run is queued
- the snapshot remains immutable across approval, resume, retry, and completion

### ConversationKVEntry

Shared per-conversation KV storage for agent-visible working state.

V1 properties:

- shared across agent switches by default
- JSON value
- size limit
- audit trail
- namespace-by-key convention

Recommended prefixes:

- `agent.<agent_key>.*`
- `shared.*`
- `user.*`
- `system.*` reserved

See `state_taxonomy.md` for the hard boundary between settings, config, KV, memory, knowledge, snapshots, and system state.

### Automation

Scheduled or event-triggered work bound to:

- an agent program
- an execution target
- an optional conversation

V1 recommendation:

- land the automation domain model and execution binding in Phase 1
- resolve the active deployment at execution time and snapshot the resolved deployment facts per automation run
- UI may come later
- conversation templates are deferred

## LLM Provider Domain

### ProviderSpec

Catalog-defined provider and model metadata.

Expected responsibilities:

- provider identity
- model catalog
- capability descriptions
- transport/protocol metadata

Important boundary:

- this is not a credential record
- it does not own secrets or rate-limit state

### ProviderCredential

Operator-managed credential bound to a provider key.

Expected responsibilities:

- secret material
- credential type
- status and health
- rate-limit configuration

V1 product constraint:

- one active credential per `provider_key`

Deferred:

- credential-level load balancing
- credential-level failover
- automatic credential routing

## Runtime Governance

### ProviderCredentialLimit

Rate-limit policy attached to one configured provider credential.

Expected responsibilities:

- request concurrency ceiling
- request rate ceiling
- token rate ceiling
- burst allowance
- backoff policy

V1 mapping:

- attach to `ProviderCredential`

### RuntimeSettings

Deployment-scoped operator settings for the Cybros runtime.

Expected responsibilities:

- job throughput settings
- default runtime governance knobs
- future deployment-scoped runtime controls

### JobConcurrencySettings

System-level settings that control how much Cybros work can advance through background jobs at once.

Expected responsibilities:

- default worker concurrency
- queue-specific concurrency where needed
- operator-tuned throughput settings

V1 recommendation:

- store in dedicated deployment-scoped runtime settings
- do not model this as an account/user preference

### ExecutionQuota

Quota policy for managed execution infrastructure.

Primary attachment:

- `ExecutionLocation`

Optional override attachment:

- `ExecutionTarget`

Expected responsibilities:

- maximum concurrent tasks
- maximum queued tasks
- default timeout
- optional CPU and memory ceilings

Important boundary:

- this protects Nexus-managed execution
- it does not rate-limit `AgentProgram` RPC calls

## Conversation State Layers

### Public Settings

Policy-gated and intended for user or agent mutation.

Examples:

- title
- default execution target
- model preference
- per-conversation agent config
- mode or persona selection

### Agent KV

Conversation-scoped working state for programmable agents.

This is not memory or knowledge retrieval. It is operational state.

### System State

Internal state not directly writable by agents.

Examples:

- DAG nodes and edges
- stream cursors
- run bookkeeping
- internal policy decisions

## Relationship Sketch

```text
User
  -> Conversations
Conversation
  -> AgentProgram
  -> AgentDeployment
  -> ExecutionTarget
  -> ConversationRuns
  -> ConversationKVEntries
ExecutionTarget
  -> ExecutionLocation
  -> Workspace
```
