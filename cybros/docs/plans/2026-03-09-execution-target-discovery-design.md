# Execution Target Discovery And Switch Policy Design

## Goal

Define how programmable agents discover execution targets and request target switches without collapsing discovery, policy, and runtime validation into one blurry mechanism.

Implementation of this design is gated by `docs/plans/2026-03-09-programmable-agent-preflight-design.md`.

Read it together with:

- `docs/product/execution_model.md`
- `docs/product/agent_rpc.md`
- `docs/plans/2026-03-09-agent-deployment-connection-design.md`
- `docs/plans/2026-03-08-phase-1-schema-cut-list.md`

## Problem Statement

The programmable-agent rebaseline already treats `ExecutionTarget` as a first-class runtime input.

But that still leaves three gaps:

- the agent cannot discover visible targets through a formal public API
- target-switch policy semantics could drift away from the rest of Cybros policy infrastructure
- discovery, policy, and hard runtime validation are easy to accidentally merge into one prompt-driven step

If that happens, target routing stops being an auditable product behavior and becomes a prompt convention.

## Core Decisions

### 1. Discovery And Switch Policy Are Orthogonal

Execution-target discovery is a read path.

Execution-target switching is a policy-gated mutation path.

They must stay separate.

The agent may inspect visible targets freely within the current draft scope without mutating the draft.

The draft changes only when the agent calls `execution_target.propose` and Cybros accepts or parks that proposal through the policy boundary.

### 2. Execution Target Discovery Uses Formal Public APIs

V1 should expose these read-side methods for `RunDraft` sessions:

- `execution_target.list`
- `execution_target.get`

Tool wrappers, skills, or prompt conventions may sit on top of those methods, but they must not replace them as the canonical contract.

This keeps target discovery auditable, typed, and testable.

### 3. Discovery Returns Visible Inventory, Not Global Raw Data

`execution_target.list` should return the targets visible in the current scope after Cybros applies:

- actor visibility rules
- target status checks
- health and availability checks
- operator policy filters

The result should be a curated inventory summary, not a dump of raw internal metadata.

Recommended summary fields:

- `id`
- `name`
- `location_label`
- `workspace_label`
- `workspace_path_hint`
- `capability_tags`
- `availability`
- `health_status`
- `is_default`
- `switch_decision_preview`

`execution_target.get` may return a richer view for one visible target, but it must remain summary-oriented and avoid exposing arbitrary internal bookkeeping by default.

### 4. Switch Policy Reuses The Existing Decision Vocabulary

Execution-target switch policy should reuse the same canonical decision shape already used by Cybros policy infrastructure:

- `allow`
- `confirm`
- `deny`

`rejected` is not a policy outcome.

It remains a runtime or approval outcome after a previously parked confirmation is denied.

This keeps target-switch approval semantics aligned with the existing approval pipeline instead of creating a second vocabulary.

### 5. Default Behavior Is Confirm-By-Default

The default execution target for a draft is the target already selected by the conversation or automation entrypoint.

V1 default switching behavior should be:

- proposing the current target again: `allow`
- proposing a different visible target: `confirm`
- proposing an invisible, inactive, unhealthy, or forbidden target: `deny`

This keeps the default product posture conservative while still allowing programmable routing.

### 6. Policy May Grant Auto-Switch Within Trusted Boundaries

Operators may configure policy overrides that turn some target switches from `confirm` into `allow`.

Recommended override dimensions:

- same `trust_group`
- same `execution_location`
- same workspace family or repo class
- same `sandboxed` posture
- capability-based restrictions
- environment fields

V1 does not need a new heavy product model for this.

`ExecutionLocation` and `ExecutionTarget` may expose explicit policy fields plus tag arrays as the inputs to the policy resolver.

### 7. Discovery Should Preview The Switch Decision

Each listed target should include a `switch_decision_preview` computed against the current draft.

That preview reuses the same decision shape:

- `outcome`
- `reason`
- `required`
- `deny_effect`

This lets the agent reason about the likely policy result before proposing a switch, while preserving Cybros as the final authority at proposal time.

The preview is advisory, not a bypass.

The actual `execution_target.propose` call still performs full policy evaluation and hard runtime validation.

### 8. `execution_target.propose` Is Draft-Only

`execution_target.propose` is only valid during `RunDraft` planning.

It must not be callable from a `ConversationRun` session because execution-target choice freezes before immutable run materialization.

If the proposal is accepted:

- Cybros updates the draft's proposed target
- Cybros re-resolves dependent runtime bindings
- Cybros re-pins the resulting deployment, provider, and governor facts before finalization

If the proposal requires confirmation:

- Cybros parks draft finalization
- the current planning session ends cleanly
- Cybros resumes locally after approval without reopening planning

If the confirmation is denied, Cybros should reject the draft instead of silently continuing with the previously prepared target-dependent plan.

### 9. Hard Runtime Validation Remains Kernel-Owned

Cybros does not decide whether the target is semantically "best."

But it must still enforce hard validity checks such as:

- target exists
- target is visible in the current scope
- target is active
- target health is acceptable
- target workspace and location are consistent
- dependent runtime bindings can be re-resolved safely

The agent may choose.

The kernel still validates and records what is allowed to happen.

### 10. `Conversation.default_execution_target_id` Is The Canonical Interactive Target

For interactive conversations, target selection should converge on one persistent field:

- `Conversation.default_execution_target_id`

If a user changes the target in the composer footer, Cybros updates that field immediately.

If an agent proposes a different target during draft planning and the proposal is accepted during finalization, Cybros updates that same field as part of the finalized draft commit.

This keeps user-driven and agent-driven target selection on one canonical state path instead of creating a separate ephemeral "next message target" concept.

### 11. The Composer Footer Should Expose Target Selection Directly

V1 should expose a target selector in the conversation composer footer, adjacent to the model selector, agent selector, and permission preset selector.

Recommended behavior:

- the current conversation target is shown as a compact pill or dropdown trigger
- changing the target persists immediately to `Conversation.default_execution_target_id`
- the control affects future drafts and runs only
- the selector uses the same visible target summary contract that powers `execution_target.list`
- stale, inactive, or no-longer-visible targets should surface an explicit warning instead of silently disappearing

The selector is a conversation-setting surface, not a hidden per-message parameter.

### 12. Targets And Deployments Need Operator Settings Surfaces

Execution-target discovery and deployment registration are not user-reachable if they exist only as runtime internals or agent-only APIs.

V1 therefore needs operator-facing settings surfaces for:

- `ExecutionTarget` management
- `AgentDeployment` registration, inspection, and activation management

The target-management surface may rely on separately owned `ExecutionLocation` and `Workspace` models, but the executable plan must still include user-reachable settings pages for target selection and deployment lifecycle management.

## RPC Contract Shape

### `execution_target.list`

Purpose:

- return visible target summaries for the current draft scope

Properties:

- read-only
- `RunDraft` session only
- paginatable in implementation if needed
- includes `switch_decision_preview` for each item

### `execution_target.get`

Purpose:

- return one visible target summary with additional capability and policy context

Properties:

- read-only
- `RunDraft` session only
- must fail with a structured visibility or not-found error if the target is not visible in the current scope

### `execution_target.propose`

Purpose:

- request a draft target change

Result:

- `decision.outcome = allow|confirm|deny`

On `allow`:

- the draft target changes immediately

On `confirm`:

- the draft parks in approval state

On `deny`:

- the draft target does not change

The method may additionally return draft-state metadata such as:

- current target
- proposed target
- resulting draft status
- approval requirement details

## Policy Contract

The target-switch policy should be implemented as a dedicated resolver for execution-target routing, but it should return the shared decision shape instead of inventing a new target-specific contract.

Recommended evaluation inputs:

- current target id
- proposed target id
- scope owner type and id
- actor type
- `ExecutionLocation.trust_group`
- `ExecutionLocation.environment`
- `ExecutionLocation.tags`
- `ExecutionTarget.sandboxed`
- `Workspace.capability_tags`
- `Workspace.tags`
- target health and availability

Recommended default outputs:

- same target: `allow`
- different visible target: `confirm`
- forbidden target: `deny`

## Non-Goals

V1 does not need:

- direct agent writes to raw target metadata
- prompt-only target discovery with no formal API
- a separate approval vocabulary for target switches
- automatic continuation on the old target after a target-switch confirmation is denied
- tool-policy reuse at the implementation object level

The system should reuse the shared decision semantics, not pretend target switching is literally a tool call.
