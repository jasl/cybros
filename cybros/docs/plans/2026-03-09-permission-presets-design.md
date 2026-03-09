# Permission Presets Design

## Goal

Define conversation-scoped and automation-scoped permission presets for programmable-agent execution so Cybros can expose a simple Codex-style permissions control without collapsing runtime policy, approval, and hard validation into one blurry setting.

Implementation of this design is gated by:

- `docs/plans/2026-03-09-programmable-agent-preflight-design.md`
- `docs/plans/2026-03-09-execution-target-discovery-design.md`
- `docs/plans/2026-03-09-agent-deployment-connection-design.md`

## Problem Statement

The programmable-agent rebaseline now has:

- explicit target-switch policy semantics
- draft-time approval semantics
- runtime tool-policy infrastructure

But it still lacks one product-level abstraction:

- a stable, user-visible permission mode that can be selected per conversation
- a non-interactive default for automation runs

Without that layer, Cybros drifts toward two bad outcomes:

- permission behavior stays hidden inside profile metadata and resolver defaults
- UI adds an attractive "permissions" control that does not map cleanly to durable runtime policy

The design should take inspiration from Codex's default/full-access presentation, but it must still compile into Cybros-owned runtime policy bundles and preserve Cybros as the final authority.

## Core Decisions

### 1. Permission Presets Are Explicit Product Fields

Permission presets should not live in `metadata`, `public_settings`, or other generic blobs.

V1 should use explicit fields on the owning product records:

- `Conversation.permission_mode`
- `Automation.permission_mode`
- `RunDraft.permission_mode`
- `ConversationRun.effective_permission_mode`

This keeps the preset durable, queryable, auditable, and compatible with the destructive schema cut.

### 2. V1 Uses Three Presets

V1 should expose exactly three user-facing presets:

- `conservative`
- `default`
- `full_access`

These are product-level permission presets, not raw sandbox or approval-policy enums.

They compile into Cybros runtime policy bundles.

### 3. `Conversation` Owns The Interactive Default

The composer control is conversation-scoped and persistent.

Changing the preset updates the conversation and affects future drafts or runs for that conversation.

It does not retroactively change:

- the currently running turn
- an already materialized `ConversationRun`
- a parked draft that already snapshotted its effective permission mode

### 4. `Automation` Defaults To `full_access`

Automations are non-interactive by default.

V1 should therefore default `Automation.permission_mode` to `full_access`.

That choice should be explicit in the domain model and execution snapshot rather than implied by scheduler behavior.

If automation configuration surfaces come later, they may expose this field directly, but the domain default should already be correct.

### 5. Presets Compile Into Runtime Policy Bundles

Permission presets should not become a second approval system.

Instead, Cybros should compile a preset into one unified bundle that is consumed by runtime resolution and draft planning.

The compiled bundle should include at least:

- base tool policy
- public-state mutation policy defaults
- target-switch policy defaults
- execution-boundary policy defaults
- a structured summary for snapshot and audit

This keeps the UI-level preset orthogonal to the lower-level policy engine.

### 6. The Preset Compiler Reuses Existing Policy Infrastructure

The compiler should build on the current `AgentCore::Resources::Tools::Policy` primitives rather than inventing a parallel engine.

Expected building blocks include:

- `Profiled`
- `Ruleset`
- `ConfirmAll`
- `AllowAll`

The preset compiler chooses how these pieces are composed for one conversation or automation scope.

### 7. Tool Visibility Remains Orthogonal

Permission presets do not replace the existing profile-based visibility model.

Tool visibility still flows through agent profile and other existing constraints.

The preset decides what happens after a tool is visible and requested:

- `allow`
- `confirm`
- `deny`

This means:

- preset selection does not automatically expose hidden tools
- preset selection does not bypass hard validation
- preset selection does not bypass schema checks, session checks, or runtime invariants

### 8. Three Presets Map To Three Different Default Behaviors

#### `conservative`

Intent:

- readable and safe by default
- all dangerous work explicitly reviewed

Recommended behavior:

- read-only operations default to `allow`
- state mutation, target switching, delegated execution, and other side-effecting operations default to `confirm`

#### `default`

Intent:

- allow low-friction work inside the current Cybros-defined boundary
- review risky or boundary-crossing work

Recommended behavior:

- read-only operations default to `allow`
- operations inside the current trusted execution boundary may default to `allow`
- boundary-crossing or high-risk operations default to `confirm`

This is the Cybros analogue of a Codex-style "default permissions" mode, but it is expressed in Cybros policy terms rather than pretending to be a full host sandbox guarantee.

#### `full_access`

Intent:

- non-interactive operation with no approval prompts

Recommended behavior:

- operations that pass hard validation default to `allow`
- approval gates are skipped
- hard validation failures still produce structured `deny` behavior

### 9. V1 Needs Stable Tool Permission Classes

The compiler should not rely only on ad hoc tool-name matching.

V1 should add or normalize stable permission metadata for tools, such as:

- `permission_class: "read"`
- `permission_class: "mutate"`
- `permission_class: "delegate"`
- `permission_class: "boundary"`

That metadata can then drive preset compilation consistently across:

- memory tools
- skills tools
- subagent tools
- future public-state mutation tools
- future execution and browser tools

If a tool does not declare a stable permission class in v1, the compiler should treat it conservatively.

Rollout ownership:

- `2026-03-09-agent-deployment-connection.md` Task 4 owns the first executable rollout of stable permission metadata and conservative fallback behavior

### 10. Target Switches Are Also Controlled By The Preset

Permission presets should influence target-switch defaults, but target-switch policy remains its own resolver.

Recommended preset interaction:

- `conservative`: different visible target defaults to `confirm`
- `default`: different visible target defaults to `confirm` unless the normal switch-policy overrides allow it
- `full_access`: different visible target may default to `allow` after visibility, health, and runtime validation checks succeed

This keeps discovery, switch policy, and hard validation separate while still making the preset meaningful.

### 11. Public-State Mutations Follow The Preset Too

The same preset bundle should also govern agent requests to mutate:

- conversation settings
- conversation config
- conversation KV

Recommended direction:

- `conservative`: write-like public API calls default to `confirm`
- `default`: low-risk in-boundary mutations may `allow`, but risky ones still `confirm`
- `full_access`: write-like public API calls default to `allow`

This keeps the "permissions" control coherent from the user's point of view instead of applying only to shell-like execution.

### 12. The Composer UI Is A First-Class Product Surface

V1 should expose the preset selector in the chat composer footer, next to model selection, the conversation agent selector, and the conversation target selector.

Recommended behavior:

- current preset is shown as a compact pill or dropdown trigger
- switching the preset persists immediately to the conversation
- the control is conversation-level, not per-message
- the UI uses clear labels:
  - `Conservative`
  - `Default`
  - `Full access`

The selector should not be implemented as a hidden message parameter.

It should use its own conversation-setting update flow.

### 13. Current Runs Are Not Retroactively Rewritten

If the user changes the preset while a turn is already running:

- the current run continues with its snapshotted effective preset
- the newly selected preset applies only to future drafts or runs

This keeps run snapshots and approval semantics coherent.

### 14. V1 Is A Cybros Runtime Policy Preset, Not A Host Sandbox Claim

The product should be explicit about the boundary:

- these presets define Cybros runtime policy behavior
- they do not claim OS-level, filesystem-level, or network-level isolation by themselves

Later execution-subsystem work may align "default" and "full_access" more closely with stronger host sandbox semantics, but v1 should not over-promise.

## Data Model Impact

The schema cut should include:

- `conversations.permission_mode`
- `automations.permission_mode`
- `run_drafts.permission_mode`
- `conversation_runs.effective_permission_mode`

`ConversationRun.snapshot.policy` or `effective_policy` should continue to carry the compiled policy summary for audit.

## Testing Direction

Before implementation is considered complete, the active plan should cover:

- conversation-level persistence of the selected preset
- automation defaulting to `full_access`
- preset compilation into expected runtime bundles
- conservative mode requiring approval for dangerous work
- default mode allowing in-boundary work while still confirming boundary-crossing work
- full-access mode skipping approval while still respecting hard validation
- target-switch behavior under each preset
- current-run snapshot immutability when the conversation preset changes mid-run
- composer UI coverage for selecting and displaying the active preset

## Phase Placement

This design belongs in the programmable-agent implementation thread, not as a later polish item.

It should be implemented alongside:

- draft/runtime snapshot work
- target-switch policy wiring
- composer model-selection and turn-start surfaces

That placement keeps permission semantics explicit before programmable-agent turns and automations become operator-facing.
