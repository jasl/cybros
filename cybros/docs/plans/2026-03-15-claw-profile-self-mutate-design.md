# Claw Profile Self-Mutate Design

## Goal

Add a narrow, deterministic self-mutate capability to bundled `claw` so the agent can propose and apply per-user `SOUL.md` and `USER.md` overrides after explicit user confirmation.

This phase does not attempt agent-program self-update, runtime restart, or code mutation. It only adds agent-owned/profile-owned prompt material overrides.

## Readiness

This work can start immediately.

The current Cybros + bundled `claw` stack already provides the required execution spine:

- bundled `claw` advertises and executes agent-owned tools through `agent_tool_catalog + tool.execute`
- `before_agent_step` already assembles `SOUL` / `USER` bootstrap sections
- `session_context` and `execution_context` already carry `user_id`
- Cybros already supports tool-level `confirm -> awaiting_approval` execution

No new DAG/runtime loop capability is required to start this phase.

## Decision Summary

### Scope

In scope:

- per-user `SOUL.md` overrides
- per-user `USER.md` overrides
- staged diff review before mutation
- explicit confirmation before apply
- agent-owned file storage outside the app repository

Out of scope:

- `IDENTITY.md`
- `HEARTBEAT.md` / `HEARTBEAT_OK`
- other bootstrap files
- bundled `claw` Ruby code mutation
- runtime restart or self-update
- Cybros platform-wide global agent storage

### Cleanup Decisions

OpenClaw-inspired `IDENTITY.md` and `HEARTBEAT.md` are intentionally not adopted for Cybros bundled `claw`.

- identity-level mutable guidance remains folded into `SOUL.md` for the current product surface
- heartbeat-style periodic background behavior should be modeled later with Cybros-native automations, not with a `HEARTBEAT.md` file

This is not a temporary omission for this phase. It is an intentional scope cleanup.

## Storage Model

Self-mutate uses an agent-owned file root with soft namespacing by `user_id`.

Suggested layout:

```text
<agent_workspace_root>/agent-owned/claw/users/<user_id>/
  SOUL.md
  USER.md
  .staged/
    <proposal_id>.json
  .history/
    <timestamp>-SOUL.md
    <timestamp>-USER.md
```

Properties:

- lives outside the app repository
- does not reuse the conversation workspace
- does not reuse conversation memory backing
- does not imply a tenant boundary
- is specific to bundled `claw` in V1

`user_id` comes from existing Cybros `session_context` / `execution_context`.

## Prompt Resolution

`before_agent_step` must resolve bootstrap text for `SOUL` and `USER` with this precedence:

1. user-scoped profile override
2. bundled default prompt file

The injected bootstrap section names remain unchanged:

- `SOUL`
- `USER`

Subagent behavior does not change:

- primary runs may inject `SOUL` / `USER`
- subagent/minimal runs continue to omit them

No separate `IDENTITY` bootstrap source is introduced.

## Tool Surface

Bundled `claw` gains three agent-owned logical tools:

- `profile_get`
- `profile_stage_update`
- `profile_apply_update`

These tools are implemented entirely inside bundled `claw`. They do not use Cybros callback RPC.

### `profile_get`

Reads the current effective profile document for one target:

- `target = soul|user`

Returns:

- `target`
- `source = bundled|override`
- `body`
- `revision`
- `override_present`

### `profile_stage_update`

Creates a staged proposal without mutating the live profile file.

Inputs:

- `target = soul|user`
- `body`
- `base_revision`
- optional summary/reason text

Returns:

- `proposal_id`
- `target`
- `base_revision`
- `next_revision`
- structured diff preview
- short summary suitable for user-facing review

### `profile_apply_update`

Applies a previously staged proposal to the live profile file.

Inputs:

- `proposal_id`

Behavior:

- validates proposal existence and status
- re-checks current live revision against the staged base revision
- archives the previous live file
- atomically writes the new live file
- marks the proposal as applied

## Approval Model

Self-mutate must be two-stage:

1. stage a proposal
2. require explicit confirmation before apply

The agent should first show the diff in a normal assistant reply. Only after user confirmation should it call `profile_apply_update`.

`profile_apply_update` must always be treated as a confirmed tool, even when the conversation permission mode is `full_access`.

That means this feature must add an explicit tool-policy exception rather than relying only on permission-class defaults.

## Concurrency And Revision Rules

Live profile files use revision-based optimistic concurrency.

- live revision is derived from the current body, for example `sha256(body)`
- `profile_stage_update` records the `base_revision`
- `profile_apply_update` fails with `revision_conflict` if the live revision changed after staging

Multiple staged proposals for the same target may coexist. Only a proposal whose `base_revision` still matches the live document may be applied.

V1 does not perform automatic merge.

## Error Model

Return stable machine-readable error codes for agent recovery:

- `claw.profile.target_invalid`
- `claw.profile.user_context_missing`
- `claw.profile.document_too_large`
- `claw.profile.proposal_not_found`
- `claw.profile.proposal_not_staged`
- `claw.profile.revision_conflict`
- `claw.profile.proposal_expired`
- `claw.profile.storage_unavailable`

## Limits

V1 should impose strict limits:

- only `soul|user`
- UTF-8 text only
- hard max document size
- hard max staged proposal size
- file root containment checks
- best-effort cleanup for expired staged proposals

These limits are required to keep prompt growth and failure modes predictable.

## Why Not Database Storage

This phase intentionally does not introduce a Cybros-wide global agent storage abstraction.

Reasons:

- the accepted scope is agent-owned/profile-owned state, not platform-owned state
- the current user need is narrow and can be satisfied with file storage
- moving directly to database storage would expand the problem into authz, admin surfaces, generic APIs, and migration semantics that are unrelated to validating self-mutate

The resulting file-based store is a deliberate V1 choice, not an accidental shortcut.

## Testing Strategy

### Unit

- profile root containment
- live revision calculation
- staging payload format
- apply path atomicity
- history archive behavior
- expired proposal cleanup
- oversize rejection

### Bundled Claw Contract

- capability handshake advertises `profile_get`, `profile_stage_update`, `profile_apply_update`
- `tool.execute` returns typed results for `profile_get`
- `tool.execute` stages proposals and returns diff previews

### Runtime / Policy

- `profile_apply_update` parks in `awaiting_approval` even under `full_access`
- denied/rejected approval paths stay DAG-visible

### Prompt Assembly

- primary prompt uses user override when present
- primary prompt falls back to bundled default when override missing
- subagent prompt still excludes `SOUL` / `USER`

### Scenario Proof

Real acceptance flow:

1. ask `claw` to adjust its collaboration style
2. `profile_get`
3. `profile_stage_update`
4. agent shows the diff
5. user confirms
6. `profile_apply_update`
7. next main-session turn reflects the new `SOUL` / `USER`

## Follow-Up Boundary

This design intentionally leaves two later problems out of scope:

- true agent-program self-update for bundled/custom agents
- any platform-level generic global agent storage abstraction

Those need separate design work and should not be backfilled into this phase.
