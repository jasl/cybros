# Runtime Governance

## Purpose

Cybros must support high DAG parallelism without collapsing external APIs, job workers, or execution hosts.

Runtime governance is the layer that keeps those resource domains independent and controllable.

V1 treats runtime governance as three separate concerns:

- provider credential limiting
- job concurrency
- execution capacity

They must not be collapsed into one global "concurrency" setting.

## Governing Principles

- DAG parallelism is allowed by default.
- Remote LLM APIs are protected by provider-credential-scoped limits.
- Agent-program RPC is bounded by deployment health and session scope, but not given a dedicated governor in v1.
- Dangerous or heavy execution is protected by execution capacity.
- Job throughput is tunable separately from remote API limits and host resource limits.
- Blocked work must park durably instead of monopolizing worker throughput.
- Deployment failures use durable scheduler backoff, but Cybros does not self-heal deployments.
- V1 configuration should live in system settings before rich product UI exists.
- Observability must start before dashboard polish.

## Governor 1: Provider Credential Limiter

Scope:

- one configured provider credential

Purpose:

- protect remote LLM APIs from request bursts, token-budget exhaustion, and credential-specific rate-limit errors

Recommended settings:

- `max_concurrent_requests`
- `requests_per_minute`
- `tokens_per_minute`
- `burst_limit`
- `backoff_policy`

Rules:

- limits are enforced per provider credential
- different credentials for the same vendor do not share one limiter by default
- this governor applies to LLM traffic only

## Governor 2: Job Concurrency

Scope:

- Cybros worker throughput

Purpose:

- control how much kernel work progresses at once without pretending that worker count is the only runtime boundary

Recommended settings:

- default worker concurrency
- queue-specific worker concurrency
- backlog or alert thresholds

Rules:

- this is scheduler throughput, not API governance
- it is not a substitute for provider rate limiting
- it is not a substitute for host execution capacity

## Governor 3: Execution Capacity

Scope:

- primary scope: `ExecutionLocation`
- optional override scope: `ExecutionTarget`

Purpose:

- protect managed execution environments from too much concurrent work or backlog

Recommended settings:

- `max_concurrent_tasks`
- `max_queued_tasks`
- `default_timeout_s`
- optional CPU and memory limits

Rules:

- base policy lives on `ExecutionLocation`
- `ExecutionTarget` may override that policy
- this governor applies to Nexus-managed execution only

## Programmable Runtime Capacity

Programmable-agent runtime availability matters, but it is not a fourth governor in V1.

V1 handles bounded runtime availability through:

- deployment activation
- deployment health status
- durable `deployment_backoff`
- operator-managed deployment replacement

Why it is not a governor yet:

- V1 recommends one active deployment per program
- there is no multi-deployment scheduler to balance across
- explicit per-deployment concurrency would add another control plane before the routing model exists

Future multi-deployment routing may introduce a dedicated deployment-capacity governor. Until then, deployment capacity remains an operator and lifecycle concern, not a separate capacity governor.

## Configuration Model

V1 exposes governance configuration through system settings.

Recommended ownership:

- provider limiter fields on provider credentials
- execution-capacity fields on `ExecutionLocation`
- override fields on `ExecutionTarget`
- job-throughput fields in dedicated instance-scoped runtime settings

Stable limiter and capacity fields should be explicit columns. Use `jsonb` only for bounded settings payloads such as queue overrides or alert thresholds.

Current operator surfaces:

- `System Settings > LLM Providers` edits provider-credential limiter fields
- `System Settings > Runtime Settings` edits instance-scoped worker concurrency, queue overrides, and alert thresholds
- `System Settings > Execution Locations` and `System Settings > Workspaces` expose the execution topology and its operator-managed safety/runtime metadata
- `System Settings > Execution Targets` shows inherited-versus-overridden `execution_capacity` policy and edits per-target overrides
- `System Settings > Runtime Governance` is the read-only observability surface for current waits and recent runtime outcomes

These pages intentionally favor edit/update flows over broad CRUD. They expose existing runtime policy and topology instead of introducing a second dashboard or inventory framework first.

## Admission Model

Provider limits and execution capacity require durable admission, not only configurable thresholds.

Use one shared coordination layer with different primitives:

- provider-side rate budgets use durable reservation and settlement semantics
- execution-side execution capacity uses durable capacity leases

Required behavior:

- atomic admission decisions
- explicit release or settlement
- durable denial or backoff reasons
- reconciliation after crashes
- durable request identifiers for provider calls and execution requests

Successful, canceled, stopped, rejected, failed, and reclaimed execution terminal paths must release execution-capacity leases exactly once.

## Wait State

Blocked work should park in a durable runtime wait state.

V1 wait reasons include:

- `provider_limit`
- `execution_capacity`
- `deployment_backoff`

Parked waits are not admitted queue occupancy.

Resume ordering should be stable and FIFO within one governed subject and wait reason.

When execution capacity releases a slot, Cybros should resume the oldest parked waiter for that governed subject, clear the node's retry gating, and kick the graph for prompt retry. `retry_at` remains the fallback path if no immediate wakeup happens.

## Snapshot Versus Live State

- `RunDraft` and `ConversationRun` snapshot the resolved governor bindings and policy facts used for audit
- reservations, leases, and backlog state remain live runtime state
- operator policy changes may invalidate an open draft before materialization
- live admission state must never be bypassed because an older snapshot exists
- automation dispatch uses the same admission model as interactive execution

## Operator Observability

The runtime-governance operator page should read durable runtime facts directly instead of replaying a separate event bus.

It is intentionally a bounded observability surface for current blockers and recent durable outcomes, not a full historical dashboard.

Current V1 observability reads:

- parked `RuntimeWait` rows for `provider_limit`, `execution_capacity`, and `deployment_backoff`
- recent non-active `ProviderBudgetReservation` rows for provider-limit outcomes
- recent non-active `ExecutionCapacityLease` rows for wakeup and recovery evidence
- recent `ConversationRun` failures whose `runtime_governors["execution_capacity"]` snapshot and error payload show `execution_capacity_denied`

The page groups those facts by governed subject so an operator can answer two questions quickly:

- which subject is currently blocking work
- whether the latest durable evidence shows parking, wakeup, recovery, or terminal denial
