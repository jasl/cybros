# Bundled Default External Agent Design

## Goal

Make Cybros itself use an external programmable agent by default.

This cut removes the remaining builtin conversation-agent runtime path and replaces it with a bundled default external agent that ships with Cybros, boots as a normal `AgentProgram` + `AgentDeployment`, and can be copied into a user-owned source tree for customization.

## Problem

Current Cybros still mixes two product models:

- the current product docs define programmable agents as external, deployment-bound, and `agent_rpc`-driven
- the interactive conversation runtime still contains a builtin fallback that materializes a direct `ConversationRun` when `conversation.agent_program_id` is blank
- the legacy `default-assistant` profile under `agents/profiles/default-assistant` is only a declarative profile with `runtime_surface.type: noop`, not a real external runtime
- the new `agents/default` directory is currently only a Bundler-generated gem skeleton, not yet a real programmable-agent program

That leaves the product in the worst possible state:

- the default user path is not programmable
- the canonical `RunDraft -> ConversationRun -> agent_rpc deployment` lifecycle is bypassed
- copying a bundled agent cannot preserve capability parity because the bundled path is not using the same runtime contract
- the bundled source tree does not yet have a program structure suitable for agent-owned tests, adapters, or domain extensions

## Decision

Adopt a bundled-default-external-agent architecture:

- delete the builtin conversation-agent runtime path
- ship at least one official bundled agent under app-root `agents/`
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
   - bundled sources live under app-root `agents/`
   - user custom sources live under a separate user-owned workspace root
7. Deployment endpoint assignment is per deployment; there are no trusted fixed well-known ports.
8. Deployment changes are rollout events, not hidden hot patches.

## Target Architecture

### Bundled Agents

`agents/` becomes the official bundled-agent source directory inside the Cybros app root. It is product-owned, versioned with Cybros, and treated as read-only application content.

Each bundled agent is represented in product state by a normal `AgentProgram`. The default bundled agent is pre-created and paired with a normal `AgentDeployment`.

The official bundled key for the first agent should be `default`.

The legacy `default-assistant` name remains only as migration input:

- legacy profile rows or profile references may be migrated from `default-assistant`
- the post-cut bundled runtime identity should be singular and should live under `agents/default`

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

## Programmable-Agent Capability Model

The point of this cut is not only to externalize the default agent. It is also to establish what a Cybros programmable agent is expected to be able to express.

### Current Contract Floor

Current Cybros already gives programmable agents a real but narrow canonical contract:

- `turn.prepare` for planning against a mutable `RunDraft`
- `turn.compose` and `turn.handle_error` for immutable run-bound output hooks
- bounded callback access to:
  - `conversation.settings.*`
  - `conversation.config.*`
  - `conversation.kv.*`
  - `execution_target.*`

That floor is enough to support:

- explicit agent identity and deployment binding
- declarative planning logic
- conversation-scoped settings/config/KV mutations
- execution-target discovery and switching proposals
- Cybros-owned approval, finalization, runtime governance, tool policy, and audit

### Capability Split

The intended split for Cybros programmable agents is:

- Cybros substrate owns:
  - canonical run lifecycle
  - tool loop and governed execution
  - approvals and runtime governance
  - transcript, audit, and deployment binding
  - stable kernel service surfaces
- agent programs own:
  - prompt-planning logic
  - persona and workflow logic
  - domain-specific orchestration
  - agent-private adapters, plugins, or off-loop services

That means the external agent must be a complete program, not a prompt bundle or profile asset.

### Capability Direction By Agent Class

The target product should eventually be able to express all of these classes without moving the canonical loop out of Cybros:

- general / universal agents
- coding agents
- research agents
- trading agents
- chat / roleplay / companion agents

The current substrate is already closest to coding and general-assistant use cases because execution governance, workspace routing, browser/file/shell tooling, and audited turn control naturally belong in Cybros.

The biggest remaining substrate gaps for the later challenge classes are:

- memory as a real programmable canonical surface rather than only an implementation direction
- knowledge / retrieval with provenance and citation semantics
- channel / connector / event surfaces for always-on and multi-surface agents
- media / artifact surfaces for richer chat, character, and desktop-style agents
- long-running event, wakeup, and risk-oriented surfaces for trading-style agents

These are substrate gaps, not reasons to move loop ownership back into the agent.

## Bundled Agent Program Structure

The bundled default agent should live under `agents/default` as a real agent program.

The structure should be gem-style for discipline and testability, but not a RubyGems package:

```text
agents/default/
  agent.yml
  README.md
  Gemfile
  Rakefile
  bin/
    setup
    server
    test
    console
  lib/
    cybros/
      agents/
        default/
          application.rb
          identity.rb
          manifest.rb
          rpc_server.rb
          rpc_dispatcher.rb
          hooks/
            prepare.rb
            compose.rb
            handle_error.rb
          domain/
          adapters/
  prompts/
    AGENT.md
    SOUL.md
    USER.md
    system.md.liquid
  test/
    test_helper.rb
    unit/
    integration/
```

Hard rules for the bundled source tree:

- no nested `.git`
- no `.gemspec`
- no RubyGems release/install semantics
- no deployment runtime config written back into the source tree
- prompt assets may live in the program tree, but they are no longer the runtime source of truth by themselves

This gives the bundled default agent the minimum shape needed for:

- direct RPC contract tests
- unit tests for planning/composition logic
- explicit domain adapters and future category-specific extensions
- a clean copy-as-custom source bootstrap

## Source Ownership And Copy-As-Custom

Bundled and custom sources must not share the same directory semantics.

### Bundled Source Root

- lives under app-root `agents/`
- owned by the application release
- not modified by product-side copy flows

### User-Owned Source Root

- configured by the operator
- shared between the Cybros app and the companion host
- on containers, mounted from the host so copies survive resets
- may also contain deployment-owned generated runtime config, but that config must live outside the git-managed source tree

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

The fork must also get a new deployment identity namespace:

- a copied agent must not retain the official bundled `agent_program_key`
- the fork flow must rewrite the copied source identity to a new stable key owned by the new `AgentProgram`
- the official bundled agent keeps its own immutable key

This makes rollback straightforward:

- runtime rollback: switch active deployment
- source rollback: use normal git in the copied source tree

Cybros does not become a git control plane. It only provides the initial repository bootstrap and enough metadata for operators to understand fork lineage and current source state.

## Deployment Config And Endpoint Allocation

Every `AgentDeployment` remains a separate process, but endpoint assignment belongs to the deployment layer, not to shared source.

The product should generate a deployment-specific runtime config file for each deployment. That file should contain at least:

- the allocated port or endpoint binding
- the deployment bearer secret reference or resolved credential input
- the deployment fingerprint
- the source path the companion host should load
- any other per-deployment transport settings

That file is runtime authority. It must not overwrite the git-managed agent source tree or the bundled-source `agent.yml`.

The first milestone should assume:

- Cybros allocates or confirms an available port for each deployment
- the allocated port is written into the deployment-specific runtime config file
- `AgentDeployment.transport_config` stores the durable control-plane copy of those settings
- the host process starts from that generated runtime config, not from a hard-coded fixed port inside the agent source
- endpoint allocation must be durable and collision-safe across concurrent registrations; a naive "scan for a free port" check is not sufficient by itself
- process launch ownership must be explicit: the companion deployment layer, not the copied source tree, is responsible for starting the per-deployment process from that generated config

This avoids both accidental collisions and a class of hijack risks where a fake process occupies a predictable port and is mistaken for the real deployment.

## Launch Ownership

The design now depends on a clear answer to "who actually starts deployment processes?"

For milestone 1, that owner should be the companion deployment layer:

- the default bundled deployment can be started by the local `Procfile.dev` entry and official compose templates
- additional custom deployments must be started from the same companion-deployment contract, using deployment-specific generated config
- Cybros may create deployment records and runtime config, but "copy as custom agent" is only considered runnable once the launch path for that deployment type is defined

If milestone 1 cannot yet fully supervise unsupported external deployment topologies, the product must downgrade the promise for those topologies from "immediately runnable" to "ready to launch with generated config". The design must not promise launched independent processes without assigning an owner.

## Deployment, Rollout, And Failure Model

Source and deployment are separate authorities.

- source changes do not become live until a deployment restart or replacement occurs
- the product does not promise in-process hot reload
- a new deployment receives its own endpoint binding and generated runtime config
- a new deployment only becomes active after passing inspection and health gates
- existing `ConversationRun` records remain pinned to the deployment selected at finalization time
- a broken new version is an acceptable operator error; Cybros only needs to preserve the ability to switch back to an older deployment or git-reverted source

This keeps rollout semantics aligned with the current deployment-binding model:

- new runs use the new active deployment
- old runs remain bound to the old deployment
- rollout is visible and explicit

Unexpected restart behavior must also stay explicit:

- if a new version fails to boot because of bad code or port conflict, it remains `inactive` / `unhealthy`
- the old active deployment stays active until a replacement passes activation
- if an active deployment dies unexpectedly, in-flight runs fail or interrupt explicitly; they do not silently reconnect to whichever process later binds the same port
- deployment-bound RPC sessions must become invalid once their deployment binding is no longer healthy or no longer active for new work
- replacement processes must establish fresh deployment-bound sessions rather than resuming the old deployment identity

## Endpoint Authenticity And Port Hijack Mitigation

Port numbers are connection coordinates, not deployment identity.

Cybros should trust a deployment only when all of these line up:

- the configured endpoint from `transport_config`
- the deployment bearer secret
- the `deployment_fingerprint`
- the expected `agent_program_key`
- the inspected protocol version and supported method set

This means a hostile or accidental replacement process that binds the same port is still not the same deployment unless it presents the expected identity and credential material.

The deployment-specific runtime config file must therefore be product-owned or operator-owned runtime state, not something the agent can rewrite by editing its own source tree.

That requires a stronger storage boundary than "not committed to git":

- git-managed agent source and deployment-owned runtime config must live in different paths
- the runtime-config path should be mounted or permissioned so the agent process cannot rewrite its own live deployment identity by ordinary source-edit actions
- shared visibility between app and host is allowed; shared write authority is not

That boundary reduces the risk that prompt hijacking or self-modification inside an agent repository can silently seize the live deployment identity.

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

They should also expose:

- whether a deployment is official bundled or forked
- the allocated endpoint
- the generated runtime-config path
- whether the deployment is merely registered or actually launched/healthy

## Migration Cut

This should be a hard cut, not a long-lived compatibility layer.

1. Introduce the bundled default external agent and companion deployment.
2. Default new conversations to that agent.
3. Remove `Built-in` from conversation UI.
4. Remove the builtin fallback code path.
5. Backfill historical builtin conversations onto an explicit system-created default bundled `AgentProgram`.
6. Migrate or collapse legacy `profile_source: "default-assistant"` `AgentProgram` rows so there is only one official bundled default identity with bundled key `default`.
7. Keep only enough trace metadata to explain that historical records originated on the legacy builtin path.

After the cut, the product mental model is singular:

- official bundled agents
- user-owned custom agents
- one external programmable lifecycle for both

## Milestone 1 Delivery Assumptions

These assumptions are intentionally narrow so the first implementation lands quickly:

- the first official companion host can be implemented in Ruby by evolving the existing programmable-agent fixture semantics into a real out-of-process executable
- development bootstrap can rely on fixed local endpoint conventions via `Procfile.dev` and compose templates
- the first operator-configured path is the user-owned agent workspace root
- the first deployment config generator can live under the shared runtime-visible root as a deployment-owned file, rather than introducing a separate orchestration service
- `AgentProgram` path handling may need to move from repo-relative `local_path` semantics to a path model that can represent mounted user-owned roots explicitly
- the first bundled agent only needs to clear an acceptance bar equivalent to a high-quality general assistant plus a light coding agent; it does not need to clear the full research / trading / roleplay challenge suite on day one
- the first bundled source should reshape `agents/default` into the canonical bundled agent program and absorb the useful prompt assets from the legacy `default-assistant` profile
- if unsupported external deployment topologies cannot yet be auto-launched, milestone 1 must explicitly scope only those topologies to generated-config readiness rather than false "immediately runnable" promises
- deeper git automation, upstream merge flows, and multi-host orchestration stay out of scope

## Acceptance And Challenge Strategy

Milestone 1 should be accepted only if the bundled default external agent can act as:

- the default interactive Cybros agent
- a strong general assistant
- a light coding agent that can reason over a workspace while still delegating governed execution and loop control back to Cybros

After that first acceptance, Cybros should use progressively harder reference classes as challenge suites:

1. general / universal agents with broader always-on, multi-surface, or plugin-heavy behavior than the milestone-1 default-agent bar
2. research and chat / roleplay agents
3. trading agents

The purpose of those challenge suites is not to force all category logic into the bundled default agent.

Their purpose is to expose which missing capabilities belong to:

- Cybros substrate
- the programmable-agent contract
- the bundled agent package
- category-specific agent programs

The passing standard is therefore architectural:

- agent loop orchestration remains Cybros-owned
- category logic remains largely agent-owned
- any capability needed across multiple categories eventually graduates into Cybros substrate rather than being left as bundled-agent-only magic

## Implementation Readiness

No design blocker remains for milestone 1 if the implementation keeps these boundaries fixed:

- bundled runtime identity is singular: bundled key `default`, source root `agents/default`
- `default-assistant` remains migration input only
- execution-capable conversations are not allowed to proceed without `agent_program_id`
- official local development and official compose flows must auto-launch both the bundled default deployment and forked custom deployments
- `generated-config-ready` is allowed only for unsupported external deployment topologies, not for the core milestone-1 acceptance path
- milestone-1 acceptance requires at least one end-to-end Cybros-owned agent loop through the bundled default agent and one through a forked custom agent

## Non-Goals

- automatic git rebase/merge/conflict resolution
- product-managed container orchestration
- hidden bundled-agent-only runtime APIs
- preserving the builtin conversation path as a compatibility fallback
- making Cybros itself the canonical owner of agent source history
