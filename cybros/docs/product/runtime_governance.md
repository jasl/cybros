# Runtime Governance

## Purpose

Runtime governance keeps Cybros responsive without collapsing unrelated limits into one global concurrency switch.

V1 keeps three concerns separate:

- provider credential limiting
- worker/job throughput
- agent-scoped execution capacity

## Governing Principles

- blocked work parks durably instead of monopolizing workers
- provider API protection is independent from agent execution capacity
- execution capacity is configured on `Agent`
- planning snapshots governor facts, but live admission still decides whether work can run
- operator observability reads durable runtime tables directly instead of replaying a separate event stream

## Provider Credential Limiter

Scope:

- one configured provider credential

Purpose:

- protect remote model APIs from concurrent bursts, RPM exhaustion, and TPM exhaustion

Representative settings:

- `max_concurrent_requests`
- `requests_per_minute`
- `tokens_per_minute`
- `burst_limit`
- `backoff_policy`

## Job Throughput

Scope:

- Cybros worker throughput

Purpose:

- control how much DAG and orchestration work progresses at once

Representative settings:

- default worker concurrency
- queue-specific worker concurrency
- backlog thresholds

## Agent Execution Capacity

Scope:

- one `Agent`

Purpose:

- protect the configured runtime path behind that agent from too much concurrent work or queue buildup

Representative settings:

- `max_concurrent_tasks`
- `max_queued_tasks`
- `default_timeout_s`
- optional CPU and memory limits

Rules:

- planning resolves execution capacity from the conversation's bound agent
- the resulting snapshot is stored on `RunDraft` and `ConversationRun`
- historical snapshots remain pinned even if the agent policy changes later
- live admission still uses durable capacity leases and runtime waits

## Durable Waits And Recovery

Blocked work parks with explicit reasons:

- `provider_limit`
- `execution_capacity`
- `deployment_backoff`

Execution-capacity admission uses durable leases. Provider-side admission uses durable reservations. Recovery paths must release or settle those records exactly once across success, failure, cancellation, and lease reclamation.

## Observability

The operator-facing runtime governance page groups durable evidence by governed subject so an operator can answer:

- which subject is blocking work now
- whether the latest durable evidence shows parking, wakeup, release, or terminal denial

Current subject groupings are:

- provider credentials
- agents
- internal runtime-binding backoff subjects
