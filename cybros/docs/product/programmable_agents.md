# Programmable Agents

## Definition

A programmable agent is a standalone trusted application that Cybros can register, inspect, configure, and invoke.

It is the app layer on top of the Cybros runtime kernel.

## V1 Constraints

- self-hosted only
- trusted by the operator
- out-of-process
- Ruby-first implementation
- language-agnostic protocol

Future Python or Rust implementations should use the same contract.

## What The Agent Owns

- prompt-planning logic
- persona and workflow selection
- hook logic
- conversation-level control through public APIs
- use of shared per-conversation KV
- optional external integrations if the operator chooses to enable them

## What The Agent Does Not Own

- the core LLM loop
- the core tool loop
- direct storage mutation inside Cybros
- direct execution on a host without going through Cybros and Nexus

## Lifecycle

### Register

`AgentProgram` source is registered with Cybros.

The operator may point Cybros at local code or clone code locally first and then register it.

### Start Deployment

A deployment may be started:

- outside Cybros
- by an operator
- or by another agent through ordinary execution capabilities if it can reach the relevant environment

### Register Deployment

An `AgentDeployment` is explicitly registered in Cybros once the deployment is reachable.

This is the unit that should become selectable for runtime use.

### Inspect

Cybros records:

- manifest
- config schemas
- healthcheck result
- supported features
- normalized deployment identity claims and pinned fingerprint inputs

Important boundary:

- `AgentProgram` remains the canonical owner of manifest and config-contract semantics
- deployment inspection snapshots are debug and audit facts, not a replacement source of truth

### Activate

The agent becomes selectable for conversations and automations.

V1 activation gate:

- exact supported `protocol_version`
- required methods present
- healthy inspection state

If activation fails, Cybros records the metadata for debugging and leaves the deployment inactive.

### Upgrade

The source revision may change over time, including through self-evolution patterns outside Cybros.

The resulting runnable unit is the currently active registered deployment for that program.

## Contract Surface

The agent contract should eventually provide:

- manifest
- global config schema
- per-conversation config schema
- healthcheck command or healthcheck entrypoint
- turn handler or hook endpoints

The transport and method boundary for those capabilities is defined by `agent_rpc`.

Contract ownership rule:

- `AgentProgram` owns the canonical manifest and config-contract versions or fingerprints
- `AgentDeployment` caches inspected runtime claims and debug snapshots for the deployed instance
- `ConversationRun` snapshots the effective contract fingerprint used for one execution attempt

## Deployment Model

- the runnable binding is an `AgentDeployment`
- a deployment may run on bare metal, in a container, or in any other Cybros-reachable environment
- the environment that runs the deployment is not a separate canonical product model in v1

V1 recommendation:

- one agent program has one active deployment at a time
- deployment registration is explicit and operator-managed
- multi-deployment routing is deferred

## Conversation Control

The agent should be allowed to control conversation-level state through public APIs.

This includes:

- public settings
- agent per-conversation config
- shared per-conversation KV
- execution-target discovery
- requests to change execution target

This control is declarative and policy-gated.

The agent requests reads or changes through public APIs, and the Cybros kernel remains authoritative for final prompt assembly, DAG mutation, approvals, retries, and audit.

During `turn.prepare`, those requested changes stay staged on the draft until Cybros finalizes the run plan.

Execution-target discovery is read-only and separate from target switching.

V1 should let the agent inspect visible targets and capability summaries through formal public APIs, then request a switch through a separate proposal path.

Target switching defaults to confirmation unless policy explicitly allows auto-switch within trusted boundaries.

Conversation and automation permission presets may tighten or relax those defaults, but they still compile into Cybros-owned policy semantics instead of becoming a second approval system.

If approval is required, Cybros persists the prepared draft result, ends the planning session, and resumes finalization locally after approval instead of reopening planning.

This does not include direct writes to system state.

## Permission Presets

Cybros should expose three runtime permission presets:

- `conservative`
- `default`
- `full_access`

These presets are selected at the product layer and compiled into runtime policy bundles.

They are not raw sandbox flags and they are not direct host-security guarantees.

Recommended ownership:

- `Conversation` stores the interactive top-level `AgentProgram` used by future turns
- `Conversation` stores the interactive preset used by future turns
- `Automation` stores the non-interactive preset and should default to `full_access`
- `ConversationRun` snapshots the effective preset it actually ran under

The composer UI should surface the active conversation agent, preset, and target next to model selection.

Conversation-level agent selection controls only the top-level programmable agent used for future turns.

Subagents remain owned by the active top-level agent for the turn that launched them and are not redirected by later conversation-level agent changes.

## Session Rule

- registration does not grant ambient write authority
- deployment bearer auth may stay lightweight in v1
- each bounded session is scoped to one deployment binding plus one conversation/run context
- callbacks use a short-lived session bearer tied to that scope
- callbacks do not reverse workflow ownership; they are scoped requests inside a Cybros-owned session
- callback authorization must expire with the session
- each transport replay or interrupted remote retry attempt opens a fresh bounded session
- callback de-duplication must survive session replay for the same logical invocation

## KV Rules

- default visibility is shared within the conversation even when agent changes
- namespace isolation is by key convention in v1
- `system.*` is reserved and not agent-writable
- KV is current-state storage in v1, not append-only audit history

## Default Template

The product should ship one default programmable-agent implementation and use it as the starter template for new agents.
