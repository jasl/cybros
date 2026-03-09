# Automation

## Purpose

`Automation` is a first-class product entrypoint for non-interactive programmable-agent execution.

It is not a downgraded conversation feature.

## Ownership

An automation binds to:

- one `AgentProgram`
- one `ExecutionTarget`
- one permission preset
- one schedule or trigger definition
- optional conversation binding for transcript continuity

It owns its own lifecycle even when it dispatches into an existing conversation.

## Default Rule

Automations are non-interactive by default.

V1 therefore defaults `Automation.permission_mode` to `full_access`.

This is a product rule, not an implementation accident.

## Runtime Rule

Automation uses the same canonical run lifecycle as interactive execution:

1. trigger fires
2. Cybros opens a `RunDraft`
3. Cybros resolves the selected program, contract, deployment, target, and governors
4. Cybros runs planning and finalization
5. Cybros materializes immutable execution records
6. Cybros writes transcript and audit output

Automation does not get a special side channel that bypasses drafts, approvals, or run snapshots.

## Deployment Resolution

Automation binds to `AgentProgram`, not a deployment id.

Each automation run resolves the currently active healthy deployment at execution time and snapshots:

- `agent_program_id`
- contract fingerprint
- resolved `agent_deployment_id`
- deployment fingerprint or revision
- deployment activation epoch
- execution target
- effective permission preset

This keeps long-lived automations compatible with operator-managed deployment replacement while preserving auditability per run.

## Conversation Binding

`conversation_id` on an automation is optional.

When present, it means:

- transcript output may flow into that conversation
- conversation-scoped settings and config may be part of the execution context

It does not mean the automation stops being its own product aggregate.

## Approval Rule

The preferred V1 path is for automation to run under `full_access` so no interactive approval is required.

If an automation uses a stricter preset and policy yields `confirm`, Cybros must not silently auto-allow. It should park the automation run in a durable manual-approval state until an operator or future approval surface resolves it.

## Product Surfaces

V1 should land the domain model and runtime semantics before full end-user automation UI.

The minimum correct surface is:

- operator-visible automation records
- durable automation-run records
- explicit target and permission binding
- audit of scheduling, dispatch, parking, and completion

## Non-Goals

V1 does not require:

- rich automation templates
- end-user workflow builders
- automation-specific prompt languages
- a separate automation execution engine
