# Domain Model

## Core Entities

### AgentProgram

A registered programmable agent package.

Expected responsibilities:

- source location and revision
- manifest snapshot
- stable config namespace
- global config contract
- per-conversation config contract
- config-schema fingerprint or version
- agent-defined configuration semantics

Important boundary:

- this is the canonical owner of agent configuration semantics
- deployment inspection may cache debug and audit snapshots, but does not replace the program contract

### AgentDeployment

The registered, connectable deployment binding Cybros can invoke for an `AgentProgram`.

Expected responsibilities:

- transport kind
- endpoint or local invocation config
- deployment bearer secret reference
- resolved revision or fingerprint
- health status
- capability and inspection snapshots
- deployment-local runtime metadata
- activation state

Important boundary:

- this is the runnable binding Cybros invokes
- it is not the canonical owner of agent configuration semantics

V1 recommendation:

- one `AgentProgram` has one active `AgentDeployment`
- registration is explicit and operator-managed
- the environment that runs the deployment is not a separate canonical product model in v1
- activation is a simple gate on exact v1 protocol version, required methods, and healthy inspection state

### ExecutionLocation

A Nexus-managed execution environment.

Examples:

- personal mac
- home workstation
- cloud VM

V1 should carry explicit policy fields and tag arrays here for:

- target visibility filtering
- trust-boundary grouping
- target-switch policy evaluation

Recommended stable fields:

- `trust_group`
- `environment`
- `tags`
- explicit execution-quota columns

### Workspace

A working directory under an execution location.

Expected responsibilities:

- root path or handle
- workspace type
- `capability_tags`
- availability state
- optional discovery tags

### ExecutionTarget

Logical pair of:

- `execution_location`
- `workspace`

This is the thing a run actually uses.

V1 invariant:

- the selected `workspace` must belong to the selected `execution_location`

V1 may expose a curated discovery summary for target selection that combines:

- `ExecutionLocation.trust_group`
- `ExecutionLocation.environment`
- `ExecutionLocation.tags`
- `Workspace.capability_tags`
- `ExecutionTarget.sandboxed`
- `Workspace.tags`

Target-switch policy should reuse the shared decision vocabulary:

- `allow`
- `confirm`
- `deny`

`rejected` remains a runtime outcome after approval denial, not a separate policy result.

### Conversation

The user-facing 1:1 chat/session aggregate.

V1 requirements:

- belongs to user
- has a default `agent_program`
- has a default `execution_target`
- has a persistent `permission_mode`
- exposes public settings for user and agent mutation
- exposes a public per-conversation agent-config surface
- does not expose storage-level mutation

V1 recommendation:

- conversation selects an `agent_program`
- the runnable deployment is resolved from that program's active deployment
- user agent changes in the composer write back to the same canonical `agent_program`
- user target changes in the composer and accepted agent target proposals both write back to the same canonical `default_execution_target`

Ownership rule in the current reset:

- user-facing records use explicit business user fields such as owner or initiating actor
- system runtime records stay global unless a direct user relationship is required

### RunDraft

A durable planning record used to assemble at most one concrete `ConversationRun`.

Expected responsibilities:

- draft status and expiry
- initiating actor when one exists
- effective permission preset for the draft
- proposed execution target
- staged public-settings patch
- staged `agent_config` patch
- staged KV operations
- resolved active deployment
- pinned deployment binding for the draft
- prepare invocation linkage
- prepared plan snapshot
- invocation idempotency context
- policy and approval decisions before queueing
- optional link to the materialized `ConversationRun`

V1 rule:

- `turn.prepare` operates on the draft
- draft-time public mutations stay staged until finalization
- approval may block draft finalization
- approval resume continues from the persisted prepared plan and does not reopen planning for the same draft
- a draft may end as `materialized`, `rejected`, `expired`, `stale`, or `canceled`
- draft finalization materializes immutable `ConversationRun`
- `ConversationRun` must not carry draft-only lifecycle states

### ConversationRun

Tracks one execution attempt and snapshots the context it ran under.

V1 snapshot fields should include:

- snapshot version
- initiating actor when one exists
- effective permission mode
- agent program id
- agent deployment id
- deployment revision or fingerprint
- deployment activation epoch
- provider credential id
- execution target
- model selection
- effective public settings
- effective `agent_config`
- `agent_config` schema fingerprint or version
- capability/policy profile
- resolved runtime governor snapshot
- queued/started/finished state

V1 rule:

- the run is materialized only after draft finalization
- the run snapshot is finalized when the run is queued
- the snapshot remains immutable across approval, resume, retry, and completion
- the run only represents an execution attempt, never an unfinalized draft

### ConversationKVEntry

Shared per-conversation KV storage for agent-visible working state.

V1 properties:

- shared across agent switches by default
- JSON value
- size limit
- current-state only in v1
- namespace-by-key convention

Important boundary:

- this is operational working state, not append-only audit history
- v1 does not require a per-write KV history table

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
- a persistent permission preset

V1 recommendation:

- land the automation domain model and execution binding in Phase 1
- resolve the active deployment at execution time and snapshot the resolved deployment facts per automation run
- treat `Automation` as its own product aggregate even when it dispatches work into an existing conversation
- default automation permission mode to `full_access` for non-interactive execution
- UI may come later
- conversation templates are deferred

## Agent RPC Runtime State

### AgentRpcSession

A bounded authorization record for one lifecycle request or one turn-hook invocation attempt.

Expected responsibilities:

- parent invocation
- pinned deployment binding
- conversation and run scope
- session bearer digest
- allowed callback methods
- expiry
- session status

Important boundary:

- this is an internal runtime-state artifact, not a user-facing product selector
- transport replay or interrupted remote retry opens a new session instead of reviving an old one

### AgentRpcInvocation

A durable logical record for one lifecycle or turn-hook call.

Expected responsibilities:

- method
- scope type and scope id
- `invocation_id`
- request hash
- result or error snapshot
- replay-safe status

V1 rule:

- uniqueness is keyed by pinned deployment binding, method, scope, and `invocation_id`
- replay after a lost reply reuses the same invocation record and opens a fresh session

### AgentRpcOperationReceipt

A de-duplicated receipt for one agent-to-Cybros callback side effect.

Expected responsibilities:

- `operation_id`
- parent invocation
- callback method
- payload hash
- applied or replayed status

V1 rule:

- de-duplication must survive session replay for the same logical invocation
- callback receipts are internal runtime state, not public conversation history

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
- explicit limiter settings

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
- burst limit
- backoff policy

V1 mapping:

- attach to `ProviderCredential`

### ProviderBudgetReservation

A durable reservation or settlement record for provider-side rate budgets.

Expected responsibilities:

- request units
- estimated token reservation
- actual token settlement
- expiry or reconciliation state
- provider request identifier for recovery

Important boundary:

- this is budget state, not execution-slot state
- it must not be modeled as a generic lease for host occupancy

### RuntimeSettings

Instance-scoped operator settings for the Cybros runtime.

Expected responsibilities:

- explicit job-throughput settings
- default runtime governance knobs
- future instance-scoped runtime controls

### JobConcurrencySettings

System-level settings that control how much Cybros work can advance through background jobs at once.

Expected responsibilities:

- default worker concurrency
- queue-specific concurrency where needed
- operator-tuned throughput settings

V1 recommendation:

- store in dedicated instance-scoped runtime settings
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

### ExecutionCapacityLease

A durable occupancy lease for execution work admitted against an execution quota.

Expected responsibilities:

- execution subject (`ExecutionLocation` or `ExecutionTarget`)
- reserved slot count
- holder identity
- heartbeat or expiry
- recovery status
- execution request identifier for reconciliation

Important boundary:

- this is slot occupancy state, not a rate-budget counter

### RuntimeWait

A durable parked-work record for blocked runtime progress.

Expected responsibilities:

- owner identity
- wait reason
- retry or wake-up time
- ordering metadata
- terminal or resumed status

V1 reason types:

- `provider_limit`
- `execution_quota`
- `deployment_backoff`

## Conversation State Layers

### Runtime Defaults

Conversation-scoped runtime selection used to open future drafts.

Examples:

- top-level `agent_program_id`
- `permission_mode`
- `default_execution_target_id`

Important boundary:

- these are first-class conversation fields, not public settings entries
- they affect future drafts and runs only
- they are snapshotted onto `RunDraft` and `ConversationRun`

### Public Settings

Policy-gated and intended for user or agent mutation.

Examples:

- title
- model preference
- mode or persona selection

Important boundary:

- this is distinct from `agent_config`
- first-class conversation runtime defaults such as `agent_program_id`, `default_execution_target_id`, and `permission_mode` do not live inside public settings
- this is the source for effective public settings snapshotted into `ConversationRun`

### Agent Config

Conversation-scoped JSON config interpreted by the selected `AgentProgram`.

Examples:

- feature toggles
- persona tuning
- workflow defaults

Important boundary:

- this is not operational KV
- the canonical schema contract lives on `AgentProgram`
- the store should be interpreted as namespaced by a stable agent-program contract namespace so switching the top-level conversation agent does not require clearing unrelated agent config

### Agent KV

Conversation-scoped working state for programmable agents.

This is not memory or knowledge retrieval. It is operational state.

V1 boundary:

- current-state only
- no append-only KV audit history is required in v1

### System State

Internal state not directly writable by agents.

Examples:

- DAG nodes and edges
- stream cursors
- run bookkeeping
- internal policy decisions
- run drafts
- agent RPC sessions, invocations, and operation receipts
- provider budget reservations
- execution capacity leases
- runtime waits

## Relationship Sketch

```text
User
  -> Conversations
Conversation
  -> AgentProgram
  -> ExecutionTarget
  -> RunDrafts
  -> ConversationRuns
  -> ConversationKVEntries
RunDraft
  -> AgentDeployment
ConversationRun
  -> AgentDeployment
ExecutionTarget
  -> ExecutionLocation
  -> Workspace
```
