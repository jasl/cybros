# Agent RPC

## Definition

`agent_rpc` is the language-agnostic wire contract between Cybros and a programmable agent deployment.

It allows:

- trusted out-of-process agent programs
- Ruby-first implementation with future Python or Rust agents
- schema-validated structured data
- controlled access to Cybros kernel surfaces

## Goals

The protocol must:

- remain language-agnostic
- stay independent from Ruby-only runtime semantics
- support inspection, health, and turn invocation
- let the agent call approved Cybros kernel surfaces
- keep Cybros internals free to evolve behind the boundary

## Non-Goals

V1 does not attempt to solve:

- cross-instance Agent2Agent protocol
- marketplace distribution
- direct Nexus integration
- direct tool-loop ownership by the agent
- generic metadata patching

## Canonical Contract Rule

The canonical protocol definition must be raw JSON Schema artifacts stored in the repository.

Language-specific SDKs may generate helpers from those artifacts, but they do not replace them as the source of truth.

## Transport

The protocol is transport-neutral at the message level.

Required V1 bindings:

- network transport for real deployments
- stdio adapter for local development, testing, and debugging

Recommended first network binding:

- WebSocket between Cybros and the registered `AgentDeployment`

All bindings must carry the same message model.

## Authentication

V1 authentication may stay lightweight:

- Cybros opens the registered deployment endpoint
- Cybros presents the deployment bearer secret for that `AgentDeployment`
- the deployment must answer `initialize` over that pinned endpoint with matching deployment identity claims
- after that succeeds, Cybros mints a short-lived session bearer for the bounded session
- callbacks must present that session bearer

## Session Model

V1 uses bounded bidirectional sessions.

That means:

- one logical session may stay open for one lifecycle request or one turn-hook invocation
- the agent may issue callbacks into Cybros kernel surfaces during that bounded session
- the session ends when the operation returns, fails, or parks

The system reopens a fresh session for later retry or resume work.

Important boundary:

- a session is an authorization attempt, not the durable identity of the logical call
- a multi-hook turn may span multiple sessions and multiple invocations

## Protocol Runtime State

The protocol needs three distinct internal runtime artifacts:

- `agent_rpc_session`
- `agent_rpc_invocation`
- `agent_rpc_operation_receipt`

These are system-state artifacts, not product-facing entities.

## Envelope

V1 uses a JSON-RPC-style envelope.

Core shapes:

- request: `jsonrpc`, `id`, `method`, `params`
- response: `jsonrpc`, `id`, `result`
- error response: `jsonrpc`, `id`, `error`
- notification: `jsonrpc`, `method`, `params`

Strict JSON-RPC 2.0 compatibility is less important than keeping the contract stable and recognizable.

## Versioning And Capabilities

Initialization must negotiate at least:

- `protocol_version`
- `agent_sdk_version`
- `supported_methods`
- `capabilities`
- deployment identity claims
- contract fingerprint or equivalent contract claim when available

Version or capability mismatch should fail fast with structured protocol errors instead of relying on best-effort compatibility.

## Bidirectional Model

The protocol allows both sides to make requests.

That means:

- Cybros calls into the agent
- the agent calls back into Cybros kernel surfaces over the same logical protocol

Business control flow still remains Cybros-driven.

Agent-to-Cybros requests are subordinate data-access or policy-gated state requests inside a Cybros-owned session, not a second workflow owner.

## Method Families

### Session / Handshake

- `initialize`
- `agent.describe`
- `agent.health`
- `agent.schemas.get`

### Turn Hooks

- `turn.prepare`
- `turn.compose`
- `turn.handle_error`

`turn.prepare` operates on a mutable `RunDraft`.

`turn.compose` and `turn.handle_error` operate on immutable run records.

### Kernel Service Surface

The callable Cybros surface should remain explicit and small in V1:

- `conversation.settings.*`
- `conversation.config.*`
- `lane.kv.*`
- `lane.prompt_buffer.*`
- `tokens.*`
- `execution_target.*`

Memory, knowledge, and future stable kernel surfaces may be added incrementally, but they should follow the same bounded-session and schema-first rules.

## Method Direction

Cybros-to-agent methods:

- `initialize`
- `agent.describe`
- `agent.health`
- `agent.schemas.get`
- `turn.prepare`
- `turn.compose`
- `turn.handle_error`

Agent-to-Cybros methods:

- `conversation.settings.get`
- `conversation.settings.update`
- `conversation.config.get`
- `conversation.config.update`
- `lane.kv.get`
- `lane.kv.set`
- `lane.kv.delete`
- `lane.kv.list`
- `lane.kv.snapshot`
- `lane.prompt_buffer.put`
- `lane.prompt_buffer.get`
- `lane.prompt_buffer.list`
- `lane.prompt_buffer.delete`
- `lane.prompt_buffer.clear`
- `lane.prompt_buffer.snapshot`
- `lane.prompt_buffer.render`
- `tokens.estimate_text`
- `tokens.estimate_messages`
- `execution_target.list`
- `execution_target.get`
- `execution_target.propose`

## Turn Control Boundary

Turn hooks must stay declarative.

The agent may:

- return prompt fragments or workflow decisions
- read approved state through Cybros surfaces
- request settings/config/lane-state mutations through Cybros surfaces
- inspect visible execution targets through Cybros surfaces
- request execution-target proposals through Cybros surfaces

The agent must not:

- write DAG internals directly
- decide final tool policy
- bypass approval or retry/resume
- mutate run snapshots or system bookkeeping

Cybros remains authoritative for final prompt assembly, DAG mutation, tool-loop orchestration, policy merge, approval handling, and durable audit.

## Draft Mutation Staging

When the agent calls kernel surfaces during `turn.prepare`, Cybros handles them through the draft boundary:

- read requests return current approved state
- execution-target discovery reads return visible inventory summaries and policy previews
- settings/config/lane-state mutations are staged on the `RunDraft`
- execution-target proposals update the draft selection state

Those staged operations commit only when draft finalization succeeds.

If the draft parks for approval, is rejected, expires, or becomes stale, Cybros must discard the staged operations instead of leaving orphaned durable side effects behind.

## Replay And Idempotency

- every Cybros-to-agent lifecycle call carries a stable `invocation_id`
- replay is only valid against the same pinned deployment binding
- every agent-to-Cybros side effect carries an `operation_id`
- operation receipts must survive session replay for the same logical invocation

Approval resume is not a replay of `turn.prepare`. It is local continuation from a persisted prepared draft.
