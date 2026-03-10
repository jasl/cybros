# Bundled Default External Agent Design

## Goal

Make Cybros itself use an external programmable agent by default.

This cut removes the remaining builtin conversation-agent runtime path and replaces it with a bundled default external agent that ships with Cybros, boots as a normal `AgentProgram` + `AgentDeployment`, and can be copied into a user-owned source tree for customization.

## Problem

Current Cybros still mixes two product models:

- the current product docs define programmable agents as external, deployment-bound, and `agent_rpc`-driven
- the interactive conversation runtime still contains a builtin fallback that materializes a direct `ConversationRun` when `conversation.agent_program_id` is blank
- the bundled `default-assistant` under `agents/profiles/default-assistant` is only a declarative profile with `runtime_surface.type: noop`, not a real external runtime

That leaves the product in the worst possible state:

- the default user path is not programmable
- the canonical `RunDraft -> ConversationRun -> agent_rpc deployment` lifecycle is bypassed
- copying a bundled agent cannot preserve capability parity because the bundled path is not using the same runtime contract

## Decision

Adopt a bundled-default-external-agent architecture:

- delete the builtin conversation-agent runtime path
- ship at least one official bundled agent under `cybros/agents`
- treat bundled agents as ordinary `AgentProgram` + `AgentDeployment` objects
- use an out-of-process companion host that speaks the normal `agent_rpc` contract
- let users copy bundled agents into a user-owned workspace root and run them through the same companion-host contract

Bundled agents may have bootstrap and operator-UX conveniences, but they must not have runtime-only privileges.

## Core Invariants

1. There is no builtin conversation execution path.
2. Every executable conversation has an explicit `agent_program_id`.
3. All executable agents, including the default one, go through `RunDraft`, finalization, `ConversationRun`, and `agent_rpc`.
4. Bundled agents and copied custom agents share the same runtime contract and governance rules.
5. The product may special-case bootstrap, distribution, and UI, but not runtime authority.
6. Source ownership is explicit:
   - bundled sources live under `cybros/agents`
   - user custom sources live under a separate user-owned workspace root
7. Deployment changes are rollout events, not hidden hot patches.

## Target Architecture

### Bundled Agents

`cybros/agents` becomes the official bundled-agent source directory. It is product-owned, versioned with Cybros, and treated as read-only application content.

Each bundled agent is represented in product state by a normal `AgentProgram`. The default bundled agent is pre-created and paired with a normal `AgentDeployment`.

### Companion Host

The bundled default agent runs out-of-process through an official companion host that implements the same `agent_rpc` contract already used by programmable-agent tests and runtime orchestration:

- `initialize`
- `agent.describe`
- `agent.health`
- `agent.schemas.get`
- `turn.prepare`
- `turn.compose`
- `turn.handle_error`

The host must also preserve the current bounded callback semantics needed by `RunDraft` planning:

- staged settings/config/KV mutations
- execution-target discovery and proposal
- approval-aware planning and resume
- stable deployment fingerprint / activation identity

### Conversation Runtime

Interactive conversations converge on the same lifecycle already used by programmable and automation paths:

- conversation has an explicit `agent_program_id`
- planning opens a `RunDraft`
- finalization materializes a `ConversationRun`
- execution binds to an active healthy `AgentDeployment`

No `nil agent_program_id -> builtin fallback -> direct ConversationRun` path remains.

## Capability Parity

Bundled agents and copied custom agents must share:

- the same `agent_rpc` method surface
- the same governance and approval path
- the same `RunDraft` and `ConversationRun` lifecycle
- the same deployment-health and run-pinning semantics

Bundled-only behavior is limited to:

- automatic bootstrap
- default visibility in operator UI
- official distribution
- official companion deployment templates
- convenience actions such as copy/fork and upgrade hints

Bundled-only runtime power is explicitly out of scope. If a capability exists, it must be available to any external agent that satisfies the same explicit contract.

## Source Ownership And Copy-As-Custom

Bundled and custom sources must not share the same directory semantics.

### Bundled Source Root

- lives under `cybros/agents`
- owned by the application release
- not modified by product-side copy flows

### User-Owned Source Root

- configured by the operator
- shared between the Cybros app and the companion host
- on containers, mounted from the host so copies survive resets

### Copy-As-Custom Flow

The product action is "copy as custom agent", not "ask the agent to copy itself".

That action:

1. copies a bundled source tree into the user-owned root
2. initializes a git repository in the new directory
3. creates an initial commit
4. tags the import point with the bundled source version
5. creates a new `AgentProgram` pointing at the copied `local_path`
6. provisions a new companion `AgentDeployment`
7. marks the new program as forked from the bundled source

This makes rollback straightforward:

- runtime rollback: switch active deployment
- source rollback: use normal git in the copied source tree

Cybros does not become a git control plane. It only provides the initial repository bootstrap and enough metadata for operators to understand fork lineage and current source state.

## Deployment, Rollout, And Failure Model

Source and deployment are separate authorities.

- source changes do not become live until a deployment restart or replacement occurs
- the product does not promise in-process hot reload
- a new deployment only becomes active after passing inspection and health gates
- existing `ConversationRun` records remain pinned to the deployment selected at finalization time
- a broken new version is an acceptable operator error; Cybros only needs to preserve the ability to switch back to an older deployment or git-reverted source

This keeps rollout semantics aligned with the current deployment-binding model:

- new runs use the new active deployment
- old runs remain bound to the old deployment
- rollout is visible and explicit

## Setup And Operator UX

Setup should leave the system with a working default external agent, not a hidden builtin fallback.

The setup flow should:

1. create the default bundled `AgentProgram`
2. register the companion `AgentDeployment`
3. inspect and activate it once healthy
4. make it the default conversation agent

Operator surfaces should show real product identities:

- official bundled agents
- custom forked agents
- source path
- fork origin
- current active deployment
- deployment health and fingerprint
- run-to-deployment lineage

Operator surfaces should not show `Built-in` as an execution identity.

## Migration Cut

This should be a hard cut, not a long-lived compatibility layer.

1. Introduce the bundled default external agent and companion deployment.
2. Default new conversations to that agent.
3. Remove `Built-in` from conversation UI.
4. Remove the builtin fallback code path.
5. Backfill historical builtin conversations onto an explicit system-created default bundled `AgentProgram`.
6. Keep only enough trace metadata to explain that those historical records originated on the legacy builtin path.

After the cut, the product mental model is singular:

- official bundled agents
- user-owned custom agents
- one external programmable lifecycle for both

## Milestone 1 Delivery Assumptions

These assumptions are intentionally narrow so the first implementation lands quickly:

- the first official companion host can be implemented in Ruby by evolving the existing programmable-agent fixture semantics into a real out-of-process executable
- development bootstrap can rely on fixed local endpoint conventions via `Procfile.dev` and compose templates
- the first operator-configured path is the user-owned agent workspace root
- deeper git automation, upstream merge flows, and multi-host orchestration stay out of scope

## Non-Goals

- automatic git rebase/merge/conflict resolution
- product-managed container orchestration
- hidden bundled-agent-only runtime APIs
- preserving the builtin conversation path as a compatibility fallback
- making Cybros itself the canonical owner of agent source history
