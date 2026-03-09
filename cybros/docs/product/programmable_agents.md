# Programmable Agents

## Definition

A programmable agent is a trusted out-of-process application that Cybros can register, inspect, configure, and invoke as a bounded runtime.

It is the app layer on top of the Cybros kernel, not a second control plane beside it.

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
- domain-specific workflow logic
- conversation-level control through Cybros public APIs
- use of shared per-conversation KV
- optional external integrations and off-loop capabilities if the operator enables them

## What The Agent Does Not Own

- the canonical run lifecycle
- final prompt assembly
- final tool policy
- direct storage mutation inside Cybros
- direct execution on a host without going through Cybros and Nexus

## Canonical Loop And Off-Loop Elasticity

The hard rule is not that every capability must be implemented inside Cybros.

The hard rule is:

- Cybros owns the canonical loop
- Cybros owns product state and governed execution
- anything that affects those concerns must pass through Cybros surfaces

External agents may still:

- maintain their own memory
- maintain their own connectors
- run their own internal tools or skills
- keep auxiliary workflows outside the canonical loop

That flexibility is allowed as long as it does not displace Cybros from the authoritative runtime path.

## Lifecycle

### Register Program

`AgentProgram` source is registered with Cybros.

### Start Deployment

A deployment may be started outside Cybros or by another agent acting through normal execution capabilities.

### Register Deployment

An `AgentDeployment` is explicitly registered in Cybros once the deployment is reachable.

This is the runtime unit Cybros invokes. It is not the user-selectable product identity.

### Inspect

Cybros records:

- manifest snapshot
- config schemas
- healthcheck result
- supported features
- normalized deployment identity claims

Important boundary:

- `AgentProgram` remains the canonical owner of manifest and config-contract semantics
- deployment inspection snapshots are debug and audit facts, not a replacement source of truth

### Activate

The program becomes selectable for conversations and automations when it has an active healthy deployment.

V1 activation gate:

- exact supported `protocol_version`
- required methods present
- healthy inspection state

### Upgrade

Source revision may change over time, including through self-evolution outside Cybros.

Selection still flows through `AgentProgram`, then resolves to the current active deployment at planning time.

## Contract Surface

The agent contract should provide:

- manifest
- global config schema
- per-conversation config schema
- healthcheck entrypoint
- turn handlers

Contract ownership rule:

- `AgentProgram` owns the canonical manifest and contract fingerprints
- `AgentDeployment` caches inspected runtime claims and debug snapshots
- `ConversationRun` snapshots the effective contract fingerprint used for one execution attempt

## Deployment Model

- the runnable binding is an `AgentDeployment`
- a deployment may run on bare metal, in a container, or in any Cybros-reachable environment
- that environment is not a separate canonical product model in v1

V1 recommendation:

- one agent program has one active deployment at a time
- deployment registration is explicit and operator-managed
- multi-deployment routing is deferred

## Conversation Control

The agent may control conversation-level state only through Cybros public APIs.

This includes:

- public settings
- per-conversation config
- shared KV
- execution-target discovery
- requests to change execution target

This control is declarative and policy-gated.

During `turn.prepare`, those requested changes stay staged on the draft until Cybros finalizes the run plan.

If approval is required, Cybros persists the prepared draft result, ends the planning session, and resumes finalization locally after approval instead of reopening planning.

## Permission Presets

Cybros exposes three runtime permission presets:

- `conservative`
- `default`
- `full_access`

These are selected at the product layer and compiled into Cybros-owned policy bundles.

Recommended ownership:

- `Conversation` stores the interactive top-level `AgentProgram`
- `Conversation` stores the interactive preset
- `Automation` stores the non-interactive preset and defaults to `full_access`
- immutable run records snapshot the effective preset they actually used

## Product Coverage Direction

The goal is not to clone one specific agent product.

The goal is for Cybros substrate plus programmable-agent logic to express:

- general assistants
- coding agents
- research agents
- trading agents
- chat and roleplay agents

Cybros should own the common substrate for those categories. Vertical logic should remain mostly in the external agent.
