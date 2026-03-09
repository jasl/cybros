# Runtime Governance Design

## Goal

Define how Cybros governs resource usage across provider APIs, worker throughput, and execution hosts without collapsing those concerns into one pseudo-concurrency knob.

Implementation of this model is gated by `2026-03-09-programmable-agent-preflight-design.md`.

## Core Decisions

### 1. Runtime Governance Stays Split Into Three Governors

V1 uses:

- `ProviderCredentialLimiter`
- `JobConcurrencySettings`
- `ExecutionQuota`

Do not collapse them into one global concurrency value.

### 2. This Design Owns The Execution-Domain Source Models

This design owns the executable schema and operator source surfaces for:

- `ExecutionLocation`
- `Workspace`
- `ExecutionTarget`

Why:

- execution-target discovery and target-switch policy need stable inputs
- execution quotas need explicit owners
- conversation and automation selectors cannot sit on top of resolver defaults or implicit filesystem state

This design does not own the conversation-facing selector UX or the public target-inventory APIs. Those belong to the programmable-agent plan.

### 3. Provider Limits Attach To Credentials

The limiter attaches to one configured provider credential, not to a provider family in the abstract.

V1 may keep one active credential per `provider_key`, but the model should not assume that is the permanent architecture.

### 4. Job Concurrency Is Scheduler Throughput

Worker concurrency is a kernel-throughput setting.

It must be tunable, but it cannot replace provider-side rate limiting or execution-host quotas.

### 5. Execution Quotas Are Location-First With Target Overrides

The base execution quota lives on `ExecutionLocation`.

`ExecutionTarget` may override that quota where a specific workspace needs different handling.

### 6. Automation Uses The Same Admission Model

Automation is not a separate execution engine.

Automation dispatch, planning, and execution must pass through the same:

- provider admission
- execution admission
- durable waits

### 7. Deployment Backoff Is A Wait Path, Not A Governor

`deployment_backoff` is a durable retry wait for unreachable or unhealthy deployments.

It is not:

- a fourth governor
- a deployment self-healing loop
- a substitute for deployment lifecycle management

### 8. Deployment Capacity Is Explicitly Deferred

Per-deployment concurrency or capacity governance is deferred until Cybros supports multi-deployment routing.

V1 handles programmable-runtime availability through:

- deployment activation
- health status
- durable backoff
- operator intervention

### 9. Observability Starts Before Dashboards

The first release may defer polished dashboards, but it must still collect:

- limiter hits
- parked waits
- lease recovery
- provider reservation recovery
- execution quota denials

## Ownership Boundary

This design owns:

- provider limiter model
- runtime settings model
- execution-domain schema
- durable admission and wait primitives
- runtime-governor resolution inputs

This design does not own:

- conversation agent selector
- conversation target selector UX
- deployment registration lifecycle
- automation scheduling semantics
