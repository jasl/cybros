# Automation / Conversation Convergence Design

## Goal

Destructively converge Cybros onto these semantics:

- `Automation` is a definition model only.
- `Conversation` is the actual execution container and DAG attachable root.
- `ConversationRun` is the only run model.
- Every automation trigger creates a new `Conversation`.
- `AutomationRun` is removed instead of preserved as a compatibility run layer.
- `RunDraft` remains planning/finalization state, but it is not a run.

## Guardrails

- Breaking changes are allowed. Do not preserve dual-read, dual-write, or compatibility shims.
- Do not regress the recent `agent_rpc` replay binding fixes or the `execution_capacity` naming cleanup.
- This cut changes automation execution topology. It does not require redefining interactive conversations as single-turn objects.

## Current Converged State

- `Automation` is a definition model only.
- `Conversation` is the execution container and DAG attachable root for each automation trigger delivery.
- `ConversationRun` is the only run model.
- `RunDraft` is conversation-scoped planning and approval state, not a run.
- Operator surfaces center on automation definitions, execution conversations, active drafts, and conversation runs.

The next section is retained as historical trace for the convergence cut. It describes the pre-cut conflicts this design removed; do not read it as the current runtime contract.

## Historical Pre-Convergence Snapshot

### Pre-Cut Code

- `Automation` is a first-class aggregate with owner, program, target, permission preset, schedule/trigger, optional `conversation_id`, and `has_many :automation_runs`.
- `AutomationRun` is a real lifecycle record with `queued -> awaiting_approval -> running -> completed/failed/rejected/canceled`, `dispatch_key`, `scheduled_for`, `approval_state`, `snapshot`, and an optional `conversation_run_id`.
- `RunDraft` is dual-entrypoint: it belongs to either `conversation` or `automation`, and its constraint enforces exactly one of those entrypoints.
- Automation execution currently flows through four objects:
  - `Automation`
  - `AutomationRun`
  - `RunDraft`
  - optional `ConversationRun`
- Standalone automations can complete without creating either a `Conversation` or a `ConversationRun`.
- Conversation-bound automations reuse an existing conversation, late-bind `conversation_id` into `trigger_snapshot`, create or reuse a pending DAG node inside that existing graph, and may mutate that conversation's settings, config, KV, and default execution target during finalization.
- Operator approval and history surfaces are keyed to `AutomationRun`, not to `Conversation`.

### Pre-Cut Product Docs

- `docs/product/automation.md` says automation is a first-class runtime entrypoint, can own its own lifecycle, and may bind to an existing conversation.
- `docs/product/run_lifecycle.md` says conversation and automation are parallel entrypoints that converge on a shared lifecycle.
- `docs/product/domain_model.md` and `docs/product/state_taxonomy.md` define both `ConversationRun` and `AutomationRun` as immutable execution records.
- `docs/product/runtime_governance.md` says `RunDraft`, `ConversationRun`, and `AutomationRun` all snapshot runtime-governor facts.

## Conflict Inventory

### Model And Schema Conflicts

- `Automation` is not definition-only because it stores `conversation_id` and validates ownership of that bound conversation.
- `AutomationRun` is a full run model, not a thin audit envelope.
- `RunDraft` is not conversation-first; it treats `automation` as an alternate execution entrypoint.
- `ConversationRun` is not the only run because automation can stop at `AutomationRun + RunDraft` with no `ConversationRun`.
- The schema has no field that says "this conversation instance was created by automation X for trigger Y". That lineage currently lives indirectly on `AutomationRun`.

### Service-Level Conflicts

- `Automations::Dispatch` materializes `AutomationRun` first and uses it as the dedupe boundary.
- `Automations::RunOrchestrator` and `Automations::RunStateRecorder` treat `AutomationRun` as the primary state carrier.
- `RunDrafts::AutomationPlanningService` supports both standalone automation execution and existing-conversation reuse.
- `RunDrafts::FinalizeService` only materializes a `ConversationRun` when a conversation can be resolved; otherwise it returns `nil`.
- `ConversationRunTracker` mirrors node lifecycle back into `AutomationRun`, which means both models are treated as live run state.

### Operator-Surface Conflicts

- `System::Settings::AutomationsController` lists latest history from `automation_runs`.
- `System::Settings::AutomationRunsController` approves and rejects parked automation work by resolving the draft through `automation_run.snapshot["draft"]["id"]`.
- The automation settings UI explicitly shows "Conversation binding", `AutomationRun.status`, `AutomationRun.approval_state`, and `conversation_run_id`.

### Documentation Conflicts

- The current product docs still describe two runtime entrypoints and two run records.
- They also explicitly bless optional conversation binding and automation-run approval parking.

## Convergence Options

### Option A: Full Collapse Into Conversation Execution Instances

Definition:

- `Automation` remains a definition only.
- Every trigger creates a fresh execution `Conversation`.
- `ConversationRun` remains the only run record.
- `RunDraft` becomes conversation-scoped planning state only.
- `AutomationRun` is deleted.

Pros:

- Matches the requested semantics exactly.
- Removes the split-brain `AutomationRun` versus `ConversationRun` lifecycle.
- Eliminates "automation without conversation" and "automation reusing existing conversation".
- Reuses the already cleaner conversation turn orchestration path.

Cons:

- Highest schema and surface churn.
- Requires rewriting operator history and approval flows.
- Deletes the current "conversation binding" behavior outright.

### Option B: Demote `AutomationRun` To Dispatch Receipt

Definition:

- Keep a table-like object only for dedupe and trigger audit.
- Remove lifecycle, approval, and run ownership from it.
- Still create a fresh `Conversation` and use `ConversationRun` for actual execution.

Pros:

- Lower churn for scheduler idempotency and operator listing queries.
- Easier migration from current jobs.

Cons:

- Preserves a second execution-adjacent object after the target semantics have already rejected it.
- Encourages old UI and service boundaries to survive under a new name.
- Violates the spirit of "`ConversationRun` is the only run" even if the table is relabeled.

### Option C: Full Collapse Plus Explicit Template Conversation

Definition:

- Same as Option A, but also add a new explicit `template_conversation_id` or similar seed field on `Automation`.
- Each trigger still creates a fresh `Conversation`, but the new instance may clone selected settings/config/KV from the template.

Pros:

- Preserves part of today's reuse value without reusing a live execution conversation.
- Makes any future bootstrap behavior explicit instead of hiding it behind `conversation_id`.

Cons:

- Adds copy semantics and product questions that are not required for this convergence.
- Increases initial scope and test burden.

## Recommendation

Choose **Option A** now.

Rationale:

- The requested target semantics are already explicit.
- The current automation path is more complex than the conversation path, not less.
- The cleanest architecture is to make automation create a new conversation instance and then enter the existing conversation-first orchestration pipeline.
- Any template/bootstrap feature should be added later under a new explicit name, not preserved accidentally via `Automation.conversation_id`.

## Recommended Target Architecture

### 1. Domain Roles

- `Automation` owns:
  - owner
  - schedule or trigger definition
  - default `AgentProgram`
  - default `ExecutionTarget`
  - default permission preset
  - task payload or prompt payload
- `Conversation` owns:
  - the actual DAG instance for one automation trigger or one interactive thread
  - attachable graph root
  - conversation-scoped settings/config/KV
  - lineage back to the originating automation definition when applicable
- `RunDraft` owns:
  - planning/finalization state for one pending attempt inside a conversation
  - approval state while the attempt is not yet finalized
  - staged mutations
- `ConversationRun` owns:
  - the only immutable runtime snapshot
  - queued/running/succeeded/failed/canceled lifecycle after finalization

### 2. Automation Trigger Lifecycle

1. Scheduler or trigger surface resolves that an automation should fire.
2. Cybros creates or finds the per-trigger execution conversation using a definition-scoped idempotency key.
3. That new conversation is preconfigured from automation defaults:
   - owner
   - `agent_program_id`
   - `default_execution_target_id`
   - `permission_mode`
   - title/metadata derived from the automation definition
4. Cybros routes into the conversation-first planning path:
   - create the automation-trigger node(s) in the new conversation
   - open a conversation-scoped `RunDraft`
   - call `turn.prepare`
5. If approval is required, the draft parks and the new conversation's pending node reflects `awaiting_approval`.
6. When finalization succeeds, Cybros materializes a `ConversationRun`.
7. DAG execution and runtime governance proceed exactly as they already do for conversation-based runs.

There is no automation execution path without a `Conversation`.

### 3. Data Model Changes

#### `Automation`

- Remove `conversation_id`.
- Remove `has_many :automation_runs`.
- Keep only definition fields and definition-level associations.

#### `Conversation`

Add explicit automation-lineage fields:

- `automation_id` nullable FK to `automations`
- `automation_dispatch_key` nullable string
- `automation_triggered_at` nullable datetime

Use them for:

- per-trigger idempotency: unique index on `(automation_id, automation_dispatch_key)`
- execution history: `automation.has_many :conversations`
- operator listing and ordering

Keep detailed trigger facts in `conversation.metadata["automation_trigger"]` and copy them into `ConversationRun.snapshot["trigger"]` for audit.

#### `RunDraft`

- Remove `automation_id`.
- Remove the dual-entrypoint validation and DB check constraint.
- Require `conversation_id`.
- Keep `materialized_conversation_run_id` if it still helps approval resume, finalization idempotency, or audit.

This keeps `RunDraft` durable while open, but strictly planning-only.

#### `ConversationRun`

- Remains the only run model.
- Still snapshots the finalized execution binding.
- For automation-originated conversations, include automation lineage in `snapshot["entrypoint"]` or `snapshot["trigger"]`.
- Keep `dag_node_id` semantics. Automation conversations may still produce additional later turns, but the initial automation attempt is just another `ConversationRun` inside its own execution conversation.

### 4. Automation History Tracking

Track automation execution history through:

- `Automation has_many :conversations`
- each execution conversation has:
  - one definition lineage
  - zero or one active `RunDraft`
  - zero or more `ConversationRun` records

Operator-facing execution history row = the execution conversation, not a deleted compatibility record.

Displayed status should be derived in this order:

1. active draft status and approval state
2. latest `ConversationRun.runtime_state`
3. terminal draft outcome when planning never materialized a run

This preserves observability without keeping `AutomationRun`.

### 5. Operator Surfaces

Show:

- automation definition fields
- latest execution conversation
- execution conversation history per automation
- derived execution status
- approval state from the active draft when applicable
- link to the execution conversation and its transcript/run details

Do not show:

- `AutomationRun` ids
- `AutomationRun.status`
- `AutomationRun.approval_state`
- `conversation_run_id` as the primary history key
- "Conversation binding" or "Standalone" as definition semantics

Approval actions should target the active `RunDraft` for an execution conversation, not a nested `AutomationRun` controller.

### 6. Approval Placement

`approval` / `awaiting_approval` belongs on:

- `RunDraft.approval_state`
- the pending DAG node state inside the execution conversation

It does **not** belong on:

- `ConversationRun`
- `Automation`
- any replacement for `AutomationRun`

The execution conversation may present a derived "awaiting approval" operator status when its active draft is parked, but that is a surface projection, not a persisted run state.

## `AutomationRun` Retirement Strategy

Default plan: delete it completely.

### Delete

- `app/models/automation_run.rb`
- `app/services/automations/run_orchestrator.rb`
- `app/services/automations/run_state_recorder.rb`
- `app/controllers/system/settings/automation_runs_controller.rb`
- `automation_runs` table and FK links
- `AutomationRun` model, service, job, controller, view, and test references

### Fold Responsibilities Elsewhere

- `dispatch_key` dedupe moves to `conversations.automation_dispatch_key`
- `scheduled_for` / trigger timing moves to `conversations.automation_triggered_at` plus trigger snapshot metadata
- run lifecycle lives only on `ConversationRun`
- pre-run approval lives only on `RunDraft`
- history lives on automation-generated conversations

### Explicitly Drop

- automation execution without conversation
- automation reuse of an existing live conversation
- automation-run-specific status machine
- any UI that treats automation execution as distinct from conversation execution

## Docs That Must Change

Primary product docs:

- `docs/product/automation.md`
- `docs/product/run_lifecycle.md`
- `docs/product/architecture.md`
- `docs/product/domain_model.md`
- `docs/product/execution_model.md`
- `docs/product/state_taxonomy.md`
- `docs/product/runtime_governance.md`
- `docs/product/README.md`
- `docs/product/migration_alignment.md`
- `docs/product/agent_rpc.md`
- `docs/product/programmable_agents.md`
- `docs/product/roadmap.md`

Current plan docs that should be marked as superseded by this design if they are still referenced as current behavior:

- `docs/plans/2026-03-09-automation-runtime-design.md`
- `docs/plans/2026-03-09-automation-runtime.md`
- `docs/plans/2026-03-09-execution-capacity-and-scheduled-automation.md`

## Non-Goals For This Cut

- preserving current conversation binding behavior
- adding a template conversation bootstrap feature
- preserving `AutomationRun` as an audit-only compatibility shell
- reworking the recent replay-binding or `execution_capacity` fixes

## Design Outcome

The converged shape should be:

- `Automation` = definition
- `Conversation` = per-trigger execution instance for automation
- `ConversationRun` = only run
- `RunDraft` = planning/finalization state only
- `AutomationRun` = deleted

That is the simplest model that satisfies the requested semantics without leaving behind a second lifecycle stack.
