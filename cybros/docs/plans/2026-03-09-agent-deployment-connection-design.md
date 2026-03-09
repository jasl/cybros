# Agent Deployment Connection Design

## Goal

Refine the programmable-agent runtime model around:

- `AgentProgram` as the selectable identity
- immutable contract snapshots between program and deployment
- explicit deployment lifecycle
- durable run planning via `RunDraft`
- replay-safe bounded `agent_rpc`

Implementation of this design is gated by `2026-03-09-programmable-agent-preflight-design.md`.

## Core Decisions

### 1. `AgentProgram` Is The Selectable Identity

Users, conversations, and automations select `AgentProgram`.

`AgentDeployment` is the reachable runtime binding and is never the primary user-facing selector.

### 2. Every Run Resolves One Immutable Contract Snapshot

Cybros must preserve a stable contract artifact between program and deployment.

V1 may represent that artifact as fingerprints and snapshots rather than a dedicated table, but the concept is required.

### 3. `RunDraft` Is The Durable Planning Object

Planning happens on `RunDraft`, not on `ConversationRun`.

The draft must survive approval parks, retries, stale detection, and finalization races.

### 4. Approval Blocks Finalization, Not Run Mutation

If target switching or another action requires confirmation:

- the prepared draft is persisted
- the planning session ends
- no immutable run is mutated in place to represent the wait
- Cybros resumes finalization locally after approval

### 5. Deployment Registration Is Explicit And Operator-Managed

V1 does not use self-registration or auto-discovery.

The intended flow is:

1. start a deployment somewhere reachable
2. register its connection details in Cybros
3. inspect and healthcheck it through `agent_rpc`
4. activate it if it satisfies the contract

### 6. Sessions Are Logical And Bounded

One lifecycle or turn-hook invocation uses one bounded logical session.

Resume or replay always opens a new session, even when the same logical invocation continues.

### 7. Target Discovery And Target Switching Stay Separate

Discovery is read-only.

Target switching is a policy-gated mutation path.

The canonical decision vocabulary remains:

- `allow`
- `confirm`
- `deny`

### 8. Permission Presets Are Runtime Inputs, Not A Second Approval System

Conversation and automation presets compile into Cybros-owned policy bundles.

They influence:

- tool behavior
- public-state mutation defaults
- target-switch defaults

They do not replace hard validation or approval semantics.

### 9. Conversation Runtime Defaults Use Canonical Fields

Interactive conversations persist:

- `agent_program_id`
- `permission_mode`
- `default_execution_target_id`

Those fields affect future drafts only.

### 10. Deployment Capacity Is Deferred

V1 handles programmable-runtime availability through deployment health, activation, and backoff.

It does not add a separate per-deployment concurrency governor before multi-deployment routing exists.
