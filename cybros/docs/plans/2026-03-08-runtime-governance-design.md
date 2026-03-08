# Runtime Governance Design

## Goal

Define how Cybros should govern resource usage when DAG execution fans out across remote LLM APIs, background jobs, and managed execution hosts.

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

## 6. V1 Configuration Lives In System Settings

V1 does not need end-user product UI for these controls.

The operator-facing system settings layer is enough.

Recommended storage direction:

- provider limiter config on the provider credential record
- execution quota config on `ExecutionLocation`
- execution quota override on `ExecutionTarget`
- job concurrency config in dedicated deployment-scoped runtime settings

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
- `burst`
- `backoff_policy`

### JobConcurrencySettings

- `default_worker_concurrency`
- `queue_overrides`
- `alert_thresholds`

### ExecutionQuota

- `max_concurrent_tasks`
- `max_queued_tasks`
- `default_timeout`
- optional `cpu_limit`
- optional `memory_limit`

## Run-Time Flow

At execution time:

1. the job system advances runnable DAG work
2. provider-bound LLM calls must pass the credential limiter
3. agent RPC calls proceed without their own limiter by default
4. execution-bound work must pass the resolved execution quota

If one of these governors blocks progress, the reason should be durable and observable.

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
