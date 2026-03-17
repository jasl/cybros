# Execution Target Discovery And Switch Policy Design

## Goal

Define how programmable agents discover execution targets and request target switches without collapsing discovery, policy, and hard runtime validation into one mechanism.

Implementation of this design is gated by `2026-03-09-programmable-agent-preflight-design.md`.

## Core Decisions

### 1. Discovery And Switch Policy Are Orthogonal

Execution-target discovery is a read path.

Execution-target switching is a policy-gated mutation path.

They must stay separate.

### 2. Discovery Uses Formal Public APIs

V1 exposes:

- `execution_target.list`
- `execution_target.get`

Tool wrappers or skills may sit on top, but they do not replace these as the canonical contract.

### 3. Discovery Returns Curated Visible Inventory

`execution_target.list` returns only targets visible in the current draft scope after Cybros applies:

- actor visibility rules
- target status checks
- health checks
- operator policy filters

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

### 4. Switch Policy Reuses The Shared Decision Vocabulary

Target switching reuses:

- `allow`
- `confirm`
- `deny`

`rejected` remains a runtime outcome after a confirmation is denied.

### 5. Default Behavior Depends On The Effective Permission Preset

Default V1 behavior:

- proposing the current target: `allow`
- proposing a different visible target under `conservative` or `default`: `confirm`
- proposing a different visible target under `full_access`: may become `allow` after visibility, health, and runtime validation checks succeed
- proposing an invisible, inactive, unhealthy, or forbidden target: `deny`

Policy overrides may still allow auto-switch inside trusted boundaries.

### 6. Discovery Should Preview Likely Switch Outcome

Each listed target should include a `switch_decision_preview` computed against the current draft.

That preview is advisory, not a bypass.

### 7. `execution_target.propose` Is Draft-Only

`execution_target.propose` is valid only during `RunDraft` planning.

If accepted:

- Cybros updates the draft target
- Cybros re-resolves dependent runtime bindings before finalization

If confirmation is required:

- Cybros parks the draft
- the planning session ends cleanly
- Cybros resumes locally after approval without reopening planning

If confirmation is denied:

- Cybros rejects the draft instead of silently continuing with the old target-dependent plan

### 8. Hard Runtime Validation Remains Kernel-Owned

Cybros must still enforce:

- target exists
- target is visible
- target is active
- target health is acceptable
- workspace and location are consistent
- dependent runtime bindings can be re-resolved safely

### 9. `Conversation.default_execution_target_id` Is The Canonical Interactive Target

For interactive conversations, target selection converges on one persistent field:

- `Conversation.default_execution_target_id`

User changes and accepted agent target proposals both update that field.

### 10. Operator And User Surfaces Depend On The Same Contract

The same summary contract should back:

- agent-facing target discovery
- conversation target selectors
- operator-facing target-management surfaces
