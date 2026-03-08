# Agent RPC Design

> **Update 2026-03-09:** Transport, deployment registration, and run-draft semantics in this document are superseded by `docs/plans/2026-03-09-agent-deployment-connection-design.md`.

## Goal

Define the first language-agnostic RPC contract between Cybros and programmable agents.

The contract must support:

- trusted out-of-process agent programs
- Ruby-first implementation with future Python/Rust compatibility
- schema-validated structured data
- conversation control through public APIs
- long-term protocol stability without freezing current internal implementation details

## Problem Statement

Cybros now has a clearer product split:

- Cybros is the runtime kernel and control plane
- Agent Host manages agent setup, health, and invocation
- programmable agents are standalone applications
- Nexus is execution-only infrastructure

That split requires a clean boundary between the Cybros side and the agent side.

Without a dedicated protocol, the system will drift toward:

- Ruby-only coupling
- internal-hook leakage
- ad hoc metadata mutation
- hard-to-port agent implementations

## Core Decisions

### 1. The Protocol Must Be Schema-First

The canonical protocol definition should be raw JSON Schema files checked into the repository.

Do not make a Ruby DSL the source of truth for wire contracts.

Reason:

- the protocol must remain language-agnostic
- Cybros will eventually support non-Ruby agents
- the wire contract should not inherit Ruby runtime semantics

## 2. EasyTalk Is Allowed Only As A Ruby Authoring Helper

`references/easy_talk` is useful as a Ruby-side ergonomics tool for:

- defining global agent config schema
- defining per-conversation agent config schema
- validating Ruby-side config objects
- exporting JSON Schema artifacts

It should not define the canonical RPC method schemas.

Reason:

- it is Ruby-specific
- its own compliance notes document meaningful JSON Schema gaps
- protocol correctness should not depend on ActiveModel-style coercion or wrapper behavior

## 3. The Protocol Should Use A JSON-RPC-Style Envelope

The first protocol version should use a transport-neutral JSON-RPC-style message envelope:

- `jsonrpc`
- `id`
- `method`
- `params`
- `result`
- `error`

This gives Cybros a familiar request/response model without forcing HTTP semantics into local process communication.

Strict JSON-RPC 2.0 compatibility is optional.

The important part is that the shape is recognizable and transport-agnostic.

## 4. V1 Transport Should Start With A Real Network Binding

The first production transport should be a real network binding between Cybros and a registered `AgentDeployment`.

Reason:

- supports remote containerized deployments
- matches the real operator-facing topology
- still allows bounded bidirectional sessions
- remains portable across agent languages

Stdio remains useful as a development and testing adapter, but it is not the architecture contract.

The protocol semantics should still be stateless.

Each request should carry enough context to be handled independently.

Business state should live in Cybros, not in a long-lived socket session.

## 5. The Protocol Must Be Bidirectional

The channel should allow both sides to issue typed requests.

That means:

- Cybros-side methods call into the agent
- agent-side methods call back into Cybros public APIs

This is required because the programmable agent is passive in the product model, but still needs to query and mutate conversation state through approved public interfaces.

V1 should implement this as bounded bidirectional sessions, not as permanent Rails-held agent connections.

One lifecycle action or one turn may use a live session.

After that operation completes, fails, or parks, the session should end.

Method direction should be explicit:

- Cybros-to-agent methods for handshake and turn hooks
- agent-to-Cybros methods for public conversation APIs

## 6. The Protocol Must Not Mirror Internal Runtime Hooks One-To-One

The existing AgentCore runtime surface is an internal kernel abstraction.

It should not be copied directly into the cross-language RPC boundary.

V1 should expose only semantic hooks that are stable from a product perspective.

Reason:

- internal lifecycle shapes may still change
- exposing every hook would freeze internals too early
- agents should own prompt logic, not Cybros kernel mechanics

## 7. Conversation Mutation Must Be Typed, Not Metadata Patch-Based

The protocol should not offer a generic `conversation.metadata.patch`.

Instead it should split mutation into explicit surfaces:

- conversation public settings
- agent per-conversation config
- shared conversation KV
- execution target proposals

Reason:

- easier schema validation
- easier UI generation
- easier audit logging
- easier policy gating
- avoids a new untyped metadata sink

## 8. Approval Blocking Is A Run-State Concern, Not A Socket-Hang Concern

When an agent proposes an execution-target switch and policy resolves to confirm, the run should block in Cybros.

The RPC request itself should not remain open indefinitely.

Instead the protocol should return a typed decision such as:

- `approved`
- `rejected`
- `awaiting_approval`

Then Cybros can park the run and resume later through normal retry/resume mechanics.

This avoids a design where Rails has to keep a suspended long-lived RPC request open while waiting for a human decision.

Turn-scoped requests should also carry stable identifiers such as:

- `conversation_run_id`
- `turn_id`
- `invocation_id`

The agent should treat those calls as stateless and re-entrant.

Retry or resume should happen in a fresh session with explicit resume context, not by assuming transport continuity.

## 9. The Protocol Needs Stable Error Taxonomy From Day One

Every protocol error should carry machine-readable structure, not only text.

At minimum:

- `code`
- `category`
- `message`
- `retryable`
- `details`

This is especially important for:

- agent deployment unavailable
- deployment connection misconfiguration
- invalid RPC payload
- unsupported capability
- approval-required decisions
- transient transport failure

## 10. Versioning Must Be Explicit

The protocol must negotiate a declared version and capabilities.

At minimum:

- `protocol_version`
- `agent_sdk_version`
- `supported_methods`
- `capabilities`

This prevents “best effort” drift as new agent languages are added.

## Proposed V1 Shape

### Envelope

Each message is a JSON object with one of these forms:

- request: `jsonrpc`, `id`, `method`, `params`
- response: `jsonrpc`, `id`, `result`
- error response: `jsonrpc`, `id`, `error`
- notification: `jsonrpc`, `method`, `params`

All IDs should be strings.

## Method Families

### Session / Handshake

- `initialize`
- `agent.describe`
- `agent.health`
- `agent.schemas.get`

### Turn Lifecycle

V1 should stay minimal:

- `turn.prepare`
- `turn.compose`
- `turn.handle_error`

Possible future additions can exist, but they should not be required for the first release.

Even without a dedicated `turn.resume` method in v1, the contract must define how retries and resumes re-enter these turn methods safely.

### Cybros Public API Over RPC

The agent should be able to invoke a constrained set of public APIs:

- `conversation.settings.get`
- `conversation.settings.update`
- `conversation.kv.get`
- `conversation.kv.set`
- `conversation.kv.delete`
- `conversation.kv.list`
- `execution_target.propose`

Additional APIs like memory or knowledge can be added later without changing the core model.

## Schema Conventions

The protocol should use a conservative JSON Schema profile.

V1 conventions:

- object results preferred over bare scalars
- unknown properties denied unless explicitly allowed
- UUIDs represented as strings
- timestamps represented as RFC 3339 strings
- enums explicit
- nullable fields represented explicitly
- method params and results defined separately

Avoid advanced schema features unless there is a clear need.

Compatibility matters more than cleverness.

## What EasyTalk Can Still Do

EasyTalk is still useful in the Ruby-first implementation in two places:

### 1. Agent Author Experience

Ruby agents can define their own config contracts with EasyTalk and export JSON Schema artifacts for Cybros to consume.

### 2. Ruby SDK Helpers

The default Ruby SDK can use EasyTalk-like ergonomics to reduce schema boilerplate when authoring agent manifests and config schemas.

But even in that case, Cybros should consume the exported JSON Schema artifact, not the Ruby model definition itself.

## Non-Goals For V1

The first agent RPC version should not attempt to solve:

- cross-instance agent-to-agent protocol
- plugin marketplace distribution
- remote host security model
- arbitrary metadata patching
- direct tool-loop ownership by the agent
- direct Nexus protocol integration

## Recommended Repository Layout

The protocol should eventually live in a dedicated tree such as:

```text
protocol/
  agent_rpc/
    v1/
      envelope.schema.json
      errors/
      methods/
        initialize.params.schema.json
        initialize.result.schema.json
        agent.describe.params.schema.json
        agent.describe.result.schema.json
        ...
```

Language-specific implementations should be generated or validated from those artifacts, not the other way around.

## Immediate Next Step

Write a concrete `agent_rpc` implementation plan that:

- defines the schema file set
- defines the first method set
- lands a production network binding first and treats any Ruby stdio adapter as optional dev/test support
- adds agent-side and Cybros-side integration tests
