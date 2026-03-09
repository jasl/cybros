# Automation

## Purpose

`Automation` is the definition model for non-interactive programmable-agent execution.

It does not carry live run state.

## Ownership

An automation binds to:

- one `AgentProgram`
- one `ExecutionTarget`
- one permission preset
- one schedule or trigger definition
- one task payload

Each trigger creates a fresh execution `Conversation` linked back to the automation definition.

## Default Rule

Automations are non-interactive by default.

V1 therefore defaults `Automation.permission_mode` to `full_access`.

This is a product rule, not an implementation accident.

## Runtime Rule

Automation uses the same canonical run lifecycle as interactive execution:

1. trigger fires
2. Cybros creates one fresh execution `Conversation`
3. Cybros opens a conversation-scoped `RunDraft`
4. Cybros resolves the selected program, contract, deployment, target, and governors
5. Cybros runs planning and finalization
6. Cybros materializes one immutable `ConversationRun`
7. Cybros writes transcript and audit output

Automation does not get a separate run model or a side channel that bypasses drafts, approvals, or conversation-backed audit.

For scheduled automation, the production path is:

1. a recurring dispatch job finds due automations
2. dispatch creates or reuses one durable execution `Conversation` per logical trigger delivery
3. an execute job atomically claims that execution conversation before invoking the shared orchestration path

Operator-visible automation state should come from execution conversations, active drafts, and conversation runs on that same job-wired path.

## Deployment Resolution

Automation binds to `AgentProgram`, not a deployment id or a live run record.

Each automation execution resolves the currently active healthy deployment at execution time and snapshots:

- `agent_program_id`
- contract fingerprint
- resolved `agent_deployment_id`
- deployment fingerprint or revision
- deployment activation epoch
- execution target
- effective permission preset

This keeps long-lived automations compatible with operator-managed deployment replacement while preserving auditability per execution conversation.

## Approval Rule

The preferred V1 path is for automation to run under `full_access` so no interactive approval is required.

If an automation uses a stricter preset and policy yields `confirm`, Cybros must not silently auto-allow. It should park the conversation-scoped `RunDraft` in a durable manual-approval state until an operator approval surface resolves it.

## Product Surfaces

V1 should land the domain model and runtime semantics before full end-user automation UI.

The minimum correct surface is:

- operator-visible automation records
- execution-conversation history per automation
- explicit target and permission binding
- audit of scheduling, dispatch, parking, conversation-run materialization, and completion

## Non-Goals

V1 does not require:

- rich automation templates
- end-user workflow builders
- automation-specific prompt languages
- a separate automation execution engine
- a second execution record outside `ConversationRun`
