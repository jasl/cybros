# Runtime Governance Design

## Goal

Define how Cybros should govern resource usage when DAG execution fans out across remote LLM APIs, background jobs, and managed execution hosts.

Implementation of this model is gated by `docs/plans/2026-03-09-programmable-agent-preflight-design.md`.

## Problem Statement

Cybros is intentionally built around concurrent DAG execution.

That creates three different pressure domains:

- remote LLM APIs have credential-specific rate limits
- job workers determine how much work the runtime kernel can advance at once
- managed execution hosts can run out of local resources

These domains are related, but they are not the same problem.

## Core Decisions

### 1. Runtime Governance Must Be Split Into Three Governors

V1 should use:

- `ProviderCredentialLimiter`
- `JobConcurrencySettings`
- `ExecutionQuota`

Do not collapse them into one global concurrency number.

## 2. Provider Limits Attach To Credentials, Not Provider Families

The limiter must be attached to one configured provider credential.

That is the real unit that experiences request and token ceilings.

In the current codebase this most closely maps to the legacy `LLMProvider` credential record.

Long-term the domain should distinguish:

- `ProviderSpec`
- `ProviderCredential`

V1 may keep a product constraint of one active credential per `provider_key`, but the model should not assume that is the permanent architecture.

## 3. Job Concurrency Is Scheduler Throughput, Not API Governance

ActiveJob or Solid Queue worker throughput must be tunable, but it should remain a separate concern.

Raising worker concurrency is necessary because DAG execution can fan out, but this alone cannot protect provider APIs or execution hosts.

## 4. Execution Quotas Protect Nexus-Managed Work Only

Execution quotas should protect:

- shell work
- file work
- browser or desktop work
- deploy and data-collection work

They should not rate-limit `AgentProgram` RPC calls.

## 5. Execution Quotas Are Location-First With Target Overrides

The base execution quota should live on `ExecutionLocation`.

`ExecutionTarget` may override it where a specific workspace needs different handling.

This preserves host-level protection while allowing workspace-level tuning.

The same execution models may also carry explicit policy fields and tag arrays used by execution-target visibility and target-switch policy resolution, but those concerns must stay separate from quota admission itself.

## 6. V1 Configuration Lives In System Settings

V1 does not need end-user product UI for these controls.

The operator-facing system settings layer is enough.

Recommended storage direction:

- provider limiter fields on the provider credential record
- execution-quota fields on `ExecutionLocation`
- execution-quota override fields on `ExecutionTarget`
- job-throughput fields in dedicated instance-scoped runtime settings

The operator-facing settings layer should expose execution-location and workspace records as the source surfaces that later execution-target management builds on.

## 7. Dashboard Can Be Deferred, But Data Collection Cannot

The first release can defer the visualization layer.

But Cybros should begin collecting facts now so Phase 4 can surface them without another architectural pass.

At minimum the kernel should produce enough data to visualize:

- agent work
- deployment work
- limiter hits
- quota denials
- backlog pressure

## Recommended V1 Settings

### ProviderCredentialLimiter

- `max_concurrent_requests`
- `requests_per_minute`
- `tokens_per_minute`
- `burst_limit`
- `backoff_policy`

### JobConcurrencySettings

- `default_worker_concurrency`
- `queue_overrides`
- `alert_thresholds`

### ExecutionQuota

- `max_concurrent_tasks`
- `max_queued_tasks`
- `default_timeout_s`
- optional `cpu_limit_millicores`
- optional `memory_limit_mb`

## Admission And Parking Rules

Provider credential limits and execution quotas require one shared durable coordination layer, but not one identical admission primitive.

Provider admission should use durable reservation and settlement semantics for:

- request budgets
- token budgets
- burst budgets

Execution admission should use durable capacity leases for:

- concurrent execution slots
- admitted execution queue occupancy
- lease expiry or heartbeat recovery

The minimum required behavior is:

- atomic admission decisions
- explicit release or settlement
- durable denial or backoff reason
- reconciliation after crashes or abandoned work
- durable request identifiers for provider calls and execution requests

If work is denied or delayed, the scheduler should park it durably and release worker capacity instead of spinning inside the worker pool.

Blocked work should use a durable wait state with explicit reasons:

- `provider_limit`
- `execution_quota`
- `deployment_backoff`

`deployment_backoff` is not a fourth governor. It is the scheduler's durable retry wait for unreachable or unhealthy programmable-agent deployments.

## Run-Time Flow

At execution time:

1. the job system advances runnable DAG work
2. provider-bound LLM calls must pass the credential limiter through the rate-budget admission path
3. agent RPC calls proceed without their own limiter by default
4. execution-bound work must pass the resolved execution quota through the capacity-lease admission path
5. denied work parks durably instead of monopolizing scheduler throughput

If one of these governors blocks progress, the reason should be durable and observable.

Deployment transport failures may also park work through `deployment_backoff`, but Cybros does not supervise or repair the deployment.

## Phase Placement

### Phase 1

Land:

- configuration model
- settings entry points
- run-time resolution rules
- baseline observability facts

### Phase 3

Land:

- full execution-quota enforcement against Nexus-managed work

### Phase 4

Land:

- dashboard views for agent work and deployment work

## Non-Goals

V1 does not need:

- per-user runtime governance
- automatic adaptive limit tuning
- product-grade end-user controls
- agent-program-specific rate limiting
