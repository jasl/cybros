# Programmable Agent Implementation Preflight

## Status

This document is the implementation gate for the current programmable-agent rebaseline.

Phase 1 and Phase 2 work should not proceed past happy-path scaffolding until the invariants in this document are reflected in the active product docs and implementation plans.

## Purpose

The current architecture direction is correct:

- `AgentDeployment` is the connectable unit
- `RunDraft` is the mutable planning object
- `ConversationRun` is an immutable execution snapshot
- runtime governance is split into provider limits, job throughput, and execution quotas

But those choices still leave a few runtime-critical invariants underdefined.

This document locks the minimum semantics needed for Cybros to support real programmable agents without a second architectural reset once remote failures, approval parks, and concurrent load show up.

## Preflight Decisions

### 1. `RunDraft` Must Be Durable While Open

`RunDraft` is not just a semantic distinction. It must survive approval parks, retries, stale detection, and finalization races as durable runtime state.

At minimum, the durable draft state must carry:

- staged public-state mutations
- pinned deployment binding
- approval state
- runtime-governor facts
- invocation bookkeeping linkage
- expiry or staleness markers

`ConversationRun` must not absorb these responsibilities by carrying draft-only states.

### 2. `turn.prepare` Is Planning-Only

`turn.prepare` may:

- read conversation state
- return prompt fragments
- propose public settings/config/KV mutations
- propose a different execution target

`turn.prepare` must not directly commit durable public state.

All draft-time mutations are staged on the `RunDraft` and remain draft-local until Cybros finalizes the draft.

If the draft is rejected, expires, is canceled, or becomes stale, Cybros discards the staged mutations.

Durable public-state mutation may happen only:

- when Cybros commits staged draft operations during finalization
- or from a run-scoped invocation that targets a materialized `ConversationRun`

This keeps approval, retry, and audit semantics coherent.

### 3. `AgentDeployment` Must Prove Identity Per Session

Registration stores connection details, but registration alone is not enough to authorize runtime control.

Each bounded session must authenticate the deployment and bind it to:

- `agent_deployment_id`
- `agent_program_id`
- pinned deployment fingerprint or revision
- activation epoch
- conversation scope
- run scope (`run_draft_id` or `conversation_run_id`)
- allowed callback methods
- expiry

Cybros must reject callbacks that are:

- outside the allowed method scope
- outside the pinned deployment identity
- outside the active session lifetime
- outside the intended conversation or run scope

Each bounded session should be represented as durable runtime state, not only implicit transport context.

### 4. Re-entry Requires Explicit Idempotency On Both Sides

Every Cybros-to-agent lifecycle or turn call must carry a stable `invocation_id`.

Cybros persists invocation bookkeeping keyed by:

- pinned deployment binding
- method
- scope (`run_draft_id` or `conversation_run_id`)
- `invocation_id`

The agent must treat repeated delivery of the same `invocation_id` as the same logical call attempt.

Every agent-to-Cybros mutation request must carry an `operation_id`.

Cybros must de-duplicate those operations across replayed sessions for the same pinned deployment binding, scope, and logical invocation.

If Cybros loses the reply after sending a request, it may re-issue the same `invocation_id` only against the same pinned deployment binding.

If the binding changed, or the prior outcome cannot be proven safely, Cybros must fail with a structured stale-or-unknown outcome error and require explicit re-planning instead of guessing.

### 5. Draft Finalization Pins The Deployment Binding

`RunDraft` resolves and pins:

- `agent_deployment_id`
- deployment fingerprint or revision
- deployment activation epoch
- provider credential
- execution target
- runtime governor facts

If the draft changes in a way that affects runtime selection, Cybros must re-resolve the dependent bindings before finalization.

Examples:

- execution-target proposal accepted
- deployment activation changes
- provider credential changes
- runtime-governance settings change in a way that invalidates the draft

If the pinned deployment becomes stale before queueing, finalization must fail with a structured stale-draft error.

Silent failover to a different active deployment is not allowed for the same draft.

### 6. Runtime Governance Needs Durable Admission, Not Just Config

Provider limits and execution quotas must use one shared durable coordination layer, but not one identical admission primitive.

Provider-side admission must support durable reservation and settlement for request and token budgets.

Execution-side admission must support durable capacity leases with expiry or heartbeat recovery.

The minimum required behavior is:

- atomic acquire
- explicit release or settlement
- lease expiry where occupancy is modeled
- crash recovery or reconciliation
- durable denial or backoff reason
- observability for acquire, deny, timeout, and lease recovery

Blocked work must park durably and release worker capacity while it waits.

The scheduler must not keep a worker occupied just because the node is waiting on:

- provider capacity
- execution quota
- deployment connectivity backoff

Rate-budget recovery and execution recovery also require durable request identifiers so retries can reconcile rather than blindly replay remote side effects.

## Required Failure-Path Coverage

Before implementation is considered architecture-complete, the active plans must cover:

- approval park and resume with no leaked draft mutations
- repeated `turn.prepare` delivery with the same `invocation_id`
- lost reply after remote execution begins
- deployment fingerprint drift between inspection and invocation
- deployment activation cutover while a draft is parked
- blocked provider-limit work parking without monopolizing workers
- blocked execution-quota work parking without monopolizing workers
- deployment connectivity backoff parking without monopolizing workers
- expired or invalid callback session scope rejection

## Checklist

Implementation should stop and return to docs if any item below is still unanswered:

- Are draft-time mutations staged instead of durably committed?
- Is `RunDraft` durable while it is open, parked, or stale?
- Does every bounded session prove deployment identity and callback scope?
- Are `invocation_id` and `operation_id` durable and de-duplicated?
- Does finalization pin one deployment binding and fail cleanly on drift?
- Is runtime governance backed by durable admission and lease recovery?
- Do blocked nodes park without holding worker throughput hostage?
- Do plan docs test failure paths, not only happy paths?

## Relationship To Active Docs

This document refines, but does not replace, the active normative product docs.

Read it together with:

- `docs/product/architecture.md`
- `docs/product/execution_model.md`
- `docs/product/agent_rpc.md`
- `docs/product/runtime_governance.md`
- `docs/plans/2026-03-09-agent-deployment-connection-design.md`
- `docs/plans/2026-03-08-runtime-governance-design.md`
