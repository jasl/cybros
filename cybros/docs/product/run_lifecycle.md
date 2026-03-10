# Run Lifecycle

## Purpose

This document is the canonical lifecycle for one programmable-agent execution.

It exists so the product model does not have to reconstruct the flow from scattered plan documents.

## Entry Points

The lifecycle may start from:

- an interactive conversation turn
- an automation trigger
- a Cybros-originated follow-up such as a scheduled continuation

All entry points converge on the same lifecycle once planning begins.

## Top-Level Runtime Gate

For the top-level manifest-driven interactive path:

- Cybros must materialize a `ConversationRun` before AgentCore runtime execution begins
- if runtime resolution is reached without that run binding, Cybros fails with `cybros.agent_runtime_resolver.programmable_run_required`
- this is not the same as explicit legacy `agent_profile` compatibility rows or subagent child-worker flows

## Canonical Flow

1. Cybros receives a trigger and opens a durable `RunDraft`.
2. Cybros resolves the owning entrypoint defaults:
   - `agent_program_id`
   - permission preset
   - execution target
   - any entrypoint-specific settings
3. Cybros resolves the selected program's current contract fingerprint and active healthy deployment.
4. Cybros resolves provider credential, runtime-governor facts, and the selected program's effective config-schema fingerprint for the draft.
5. Cybros opens a bounded `agent_rpc` session and calls `turn.prepare`.
6. During planning, the agent may read approved state and request staged public mutations through Cybros kernel surfaces.
7. If the agent proposes a different execution target, Cybros evaluates visibility, policy, and hard validation before continuing.
8. If policy or approval requires a human decision, Cybros persists the prepared draft and parks it without materializing a run.
9. Once finalization is allowed, Cybros atomically:
   - commits staged draft mutations
   - materializes one immutable `ConversationRun`
   - snapshots the finalized runtime inputs, including the draft-pinned config-schema fingerprint
   - hands execution to the runtime kernel
10. Cybros executes the run under the pinned deployment binding, provider binding, target binding, and governor snapshot.
11. When execution completes or fails, Cybros calls `turn.compose` or `turn.handle_error` as appropriate.
12. Cybros persists transcript output, final run facts, and audit events.

## Planning Rule

`turn.prepare` is planning-only.

It may:

- return prompt fragments
- return workflow decisions
- cause staged settings, config, or KV mutations through Cybros surfaces
- inspect or propose execution targets

It may not:

- durably commit public state by itself
- mutate `ConversationRun`
- bypass policy or approval

## Approval Park And Resume

If approval is required:

- Cybros persists the prepared draft result
- the active planning session ends
- staged mutations stay uncommitted
- no immutable run record is mutated in place to represent the wait
- later conversation-level changes affect future drafts only; they do not rewrite the parked draft in place

When approval resumes:

- Cybros continues local finalization from the persisted prepared draft
- Cybros does not send a second `turn.prepare` for the same prepared draft
- Cybros validates that the parked binding is still fresh before finalization succeeds

## Finalization Rule

Finalization pins exactly one runtime selection for the run:

- one `AgentProgram`
- one contract fingerprint
- one `AgentDeployment`
- one deployment fingerprint or revision
- one deployment activation epoch
- one execution target
- one effective permission preset
- one provider credential
- one `agent_config_schema_fingerprint`
- one runtime-governor snapshot

If any pinned binding becomes stale before finalization completes, Cybros must fail or re-plan explicitly instead of silently drifting.

## Retry And Replay

Two kinds of retry must stay separate:

### Transport Or Reply Retry

- Cybros may replay the same `invocation_id` only against the same pinned binding
- a fresh bounded session may carry the replay
- callback side effects must still de-duplicate through `operation_id`

### Approval Resume

- approval resume is not a replay of `turn.prepare`
- it is a continuation from the persisted prepared draft

## Failure Paths

The lifecycle must explicitly cover:

- selected program has no active healthy deployment for the current published contract
- attempted top-level runtime execution without a materialized `ConversationRun`
- deployment connectivity failure
- lost reply after remote execution begins
- deployment identity drift
- activation cutover while a draft is parked
- provider-limit parking
- execution-capacity parking
- rejected approval
- expired or stale draft finalization

These are product semantics, not implementation afterthoughts.

## Conversation And Automation

Interactive conversations and automations share the same lifecycle.

The differences are in the entrypoint defaults and operator surfaces:

- conversations emphasize human-visible selection and approval
- automations emphasize scheduling, fresh execution conversations, and non-interactive defaults

Neither entrypoint gets its own ad hoc run model.
