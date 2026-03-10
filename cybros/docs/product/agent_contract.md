# Agent Contract

## Purpose

This document defines the stable contract boundary between Cybros and programmable agents.

The goal is to keep three concerns separate:

- the product identity a user selects
- the immutable contract the runtime executes against
- the live deployment Cybros can currently reach

## Hard Rules

- `AgentProgram` is the user-selectable identity.
- `AgentDeployment` is the connectable runtime binding.
- Cybros owns the canonical contract and the canonical run lifecycle.
- Deployment inspection facts are never the source of truth for product semantics.
- External agents may keep additional off-loop capabilities, but the canonical loop still passes through Cybros.
- there is no builtin conversation-agent runtime fallback

## Product Entities

### AgentProgram

`AgentProgram` is the stable product identity for a programmable agent.

It owns:

- display identity and operator-facing registration
- source package or source reference
- explicit source ownership metadata (`bundled` vs `custom`)
- bundled key or fork ancestry
- stable config namespace
- operator-managed global config state
- the currently published contract fingerprint

Users, conversations, and automations select `AgentProgram`, not a deployment.

The official bundled default identity is singular:

- bundled key `default`
- source root `agents/default`

### Agent Contract Version

Every programmable agent execution should resolve against one immutable contract artifact.

That artifact includes:

- manifest snapshot
- supported `agent_rpc` protocol version
- global config schema
- per-conversation config schema
- declared capabilities and kernel-surface expectations
- one stable contract fingerprint

V1 does not require a standalone `agent_contract_versions` table, but it must preserve the concept. It is acceptable for V1 to persist the current published contract as snapshots and fingerprints on `AgentProgram`, `AgentDeployment`, `RunDraft`, and `ConversationRun`.

### AgentDeployment

`AgentDeployment` is the registered, reachable runtime binding Cybros invokes.

It owns:

- transport kind
- endpoint or local invocation details
- generated runtime-config location when the deployment is managed locally
- deployment bearer secret reference
- deployment fingerprint or resolved revision
- activation and health state
- inspection snapshots
- observed capability claims

It does not own:

- the canonical manifest
- global config semantics
- per-conversation config semantics
- user-facing selection semantics

## Selection Rule

Interactive conversations and automations persist `agent_program_id`.

At planning time Cybros resolves:

1. the selected `AgentProgram`
2. the current published contract fingerprint for that program
3. the active healthy deployment that can satisfy that contract

If no active healthy deployment exists, Cybros must block new draft materialization with an explicit stale-selection error instead of silently picking an arbitrary runtime.

No execution-capable conversation may fall back to a nil-program builtin path.

## Contract Ownership

Canonical ownership lives on `AgentProgram` and the published contract artifact.

`AgentDeployment` may cache:

- inspected manifest snapshot
- inspected schema snapshot
- observed capability snapshot

Those are debug and audit facts. They do not replace the published contract as the product source of truth.

## Global Config Rule

Programmable agents may expose operator-managed global configuration in addition to per-conversation configuration.

V1 rules:

- the global config state is stored by Cybros under the owning `AgentProgram`
- the global config schema belongs to the published contract
- runs snapshot the global-config fingerprint they executed against
- in-run callbacks do not directly mutate global config unless a dedicated operator-approved surface exists

## Run Snapshot Rule

`RunDraft` pins:

- `agent_program_id`
- contract fingerprint
- `agent_deployment_id`
- deployment fingerprint or revision
- deployment activation epoch

`ConversationRun` snapshots the finalized result of that binding.

Once materialized, the run does not silently drift to a different contract or deployment.

## Activation Rule

Activation is a gate on a deployment, not on the program itself.

V1 activation requires:

- exact supported `protocol_version`
- required methods present
- successful inspection
- healthy deployment state
- deployment identity claims matching the registered binding

Activation does not create a compatibility layer or routing matrix.

## Deployment Launch Ownership

Managed-local deployments are still ordinary `AgentDeployment` records. They differ only in who launches them:

- official local development and official compose use a Cybros-managed local supervisor
- launch state is derived from deployment facts such as allocated endpoint, generated runtime config, activation, and health
- the source tree never becomes the authority for launch ownership
- unsupported external topologies remain operator-managed rather than reintroducing a builtin path

## Deferred Direction

Future multi-deployment routing, hosted agents, or managed rollout strategies may add more explicit contract-version records and richer deployment selection.

They must still preserve:

- `AgentProgram` as the selectable identity
- one immutable contract per run
- deployment facts as runtime observations rather than product truth
