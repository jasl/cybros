# Runtime Governance

## Purpose

Cybros must support high DAG parallelism without collapsing external APIs, job workers, or execution hosts.

Runtime governance is the layer that keeps those resource domains independent and controllable.

V1 should treat runtime governance as three separate concerns:

- provider credential limiting
- job concurrency
- execution quotas

They must not be collapsed into one global "concurrency" setting.

## Governing Principles

- DAG parallelism is allowed by default.
- Remote LLM APIs are protected by provider-credential-scoped limits.
- Agent program invocation is not rate-limited by default.
- Dangerous or heavy execution is protected by execution quotas.
- Job throughput is tunable separately from remote API limits and host resource limits.
- Blocked work must park durably instead of monopolizing worker throughput.
- V1 configuration should live in system settings, not yet in end-user product UI.
- Observability must be collected before the final dashboard exists.

## Provider Model

The LLM domain should distinguish:

- `ProviderSpec`
- `ProviderCredential`

`ProviderSpec` describes catalog capabilities.

`ProviderCredential` carries operator-managed secret material, status, and limiter configuration.

V1 product rule:

- one active credential per `provider_key`

Deferred:

- credential-level load balancing
- credential-level failover
- automatic credential routing

## Governor 1: Provider Credential Limiter

### Scope

This governor applies to one configured provider credential, not to a provider family in the abstract.

In product terms, this attaches to `ProviderCredential`.

### Purpose

Protect remote LLM APIs from:

- request bursts
- concurrent run spikes
- token-budget exhaustion
- credential-specific rate-limit errors

### Recommended Settings

- `max_concurrent_requests`
- `requests_per_minute`
- `tokens_per_minute`
- `burst`
- `backoff_policy`

### Rules

- limits are enforced per provider credential
- different credentials for the same vendor do not share one limiter by default
- this governor only applies to LLM traffic
- it does not limit `AgentProgram` RPC calls

## Governor 2: Job Concurrency

### Scope

This governor controls how much Cybros work is allowed to progress through job workers at once.

### Purpose

Protect the runtime kernel from under-utilization or starvation caused by overly conservative worker settings.

### Recommended Settings

- default worker concurrency
- queue-specific worker concurrency
- optional backlog thresholds or alert thresholds

### Rules

- this is a scheduler-throughput setting
- it is not a substitute for provider rate limiting
- it is not a substitute for host execution quotas
- V1 should raise the default concurrency above the current conservative baseline
- operators must be able to tune it in system settings based on deployment shape

## Governor 3: Execution Quota

### Scope

This governor protects managed execution environments.

Primary scope:

- `ExecutionLocation`

Optional override scope:

- `ExecutionTarget`

### Purpose

Protect local or remote machines from resource exhaustion caused by:

- too many concurrent code-execution tasks
- unbounded queued work
- excessive task duration
- optional CPU or memory pressure

### Recommended Settings

- `max_concurrent_tasks`
- `max_queued_tasks`
- `default_timeout`
- optional `cpu_limit`
- optional `memory_limit`

### Rules

- the default policy lives on `ExecutionLocation`
- `ExecutionTarget` may override it when a specific workspace needs stricter or looser behavior
- this governor applies to Nexus-managed execution
- it does not rate-limit the agent process itself

## Configuration Model

V1 should expose configuration through system settings.

Recommended ownership:

- provider-credential limiter config on the provider credential record
- execution quota config on `ExecutionLocation`
- execution quota override on `ExecutionTarget`
- job concurrency config in a dedicated deployment-scoped runtime settings store

Product-grade user-facing controls may come later.

## Admission Model

Provider-credential limits and execution quotas require durable admission, not just configurable thresholds.

V1 should use one shared coordination layer with two different admission primitives:

- provider-side rate budgets use durable reservation and settlement semantics
- execution-side quotas use durable capacity leases

The authoritative runtime behavior should include:

- atomic admission decisions
- explicit release or settlement
- lease expiry or heartbeat-based recovery for execution capacity
- durable denial or backoff reasons
- reconciliation after worker or process crashes
- durable request identifiers for provider calls and execution requests

Blocked work should park and re-enqueue later without occupying a job worker while it waits.

### Provider Admission Primitive

Provider admission protects time-window budgets such as:

- concurrent request ceiling
- requests per minute
- tokens per minute
- burst allowance

It should use durable reservation and settlement semantics rather than generic host-capacity leases.

Important consequences:

- token reservations may be estimated before the call and settled after the call
- reconciliation must recover stranded reservations after crashes or lost replies
- retry safety requires a durable provider-request identifier

### Execution Admission Primitive

Execution admission protects host occupancy and backlog.

It should use durable capacity leases with expiry or heartbeat recovery.

Important consequences:

- lease holders represent admitted execution work
- lease recovery must reconcile abandoned or unknown execution work
- retry safety requires a durable execution-request identifier

### Wait State

Blocked work should park in a durable runtime wait state.

V1 wait reasons include:

- `provider_limit`
- `execution_quota`
- `deployment_backoff`

Parked waits are not the same thing as admitted queue occupancy.

For execution quotas, `max_queued_tasks` should count execution work already admitted into the location or target queue, not globally parked waits.

Resume ordering should be stable and FIFO within one governed subject and wait reason.

## Run-Time Behavior

At execution time:

1. Cybros schedules work through its job system.
2. LLM calls must pass the provider-credential limiter through the rate-budget admission path.
3. Agent program RPC calls proceed without a dedicated rate limiter by default.
4. Deployment connectivity and transport failures must still be observable through health signals plus scheduler retry or backoff behavior.
5. Nexus-bound execution must pass the resolved execution quota for the selected target through the capacity-lease admission path.
6. If work is denied or delayed, the node should park durably rather than spin inside the worker pool.

If a governor blocks work, the reason should be durable and observable.

Governor snapshots versus live state:

- `RunDraft` and `ConversationRun` snapshot the resolved governor bindings and policy facts used for audit
- reservations, leases, and backlog state remain live runtime state
- operator policy changes may invalidate an open draft before materialization
- live admission state must never be bypassed just because an older snapshot exists

## Dashboard Direction

The dashboard can land later, but data collection should start in the kernel phases.

The first useful visualizations are:

### Agent Work

- run state
- node progress
- provider call activity
- retries
- approval waits
- limiter hits and backoff events

### Deployment Work

- deployment session counts
- deployment unavailable intervals
- scheduler backoff events for deployment connectivity pressure
- per-location running tasks
- queue depth
- quota denials
- timeouts
- lease recovery events
- provider reservation reconciliation events
- execution-target override usage

## Phase Placement

### Phase 1

Land:

- provider-credential limiter model/config
- job concurrency settings
- execution quota model/config
- baseline events and counters

### Phase 3

Wire execution quotas fully into Nexus and execution planning.

### Phase 4

Add developer-grade visualization for agent work and deployment work.
