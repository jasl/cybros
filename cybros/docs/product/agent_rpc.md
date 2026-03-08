# Agent RPC

## Definition

`agent_rpc` is the language-agnostic RPC contract between the Cybros side and a programmable agent.

It is the protocol boundary that allows:

- trusted out-of-process agent programs
- Ruby-first implementation with future Python or Rust agents
- schema-validated structured data
- conversation control through public APIs

## Goals

The protocol must:

- remain language-agnostic
- stay independent from Ruby-only runtime semantics
- support setup, inspection, health, and turn invocation
- let the agent query and mutate approved conversation state
- keep Cybros internals free to evolve behind the boundary

## Non-Goals

V1 does not attempt to solve:

- cross-instance agent-to-agent protocol
- marketplace distribution
- direct Nexus integration
- direct tool-loop ownership by the agent
- generic metadata patching

## Canonical Contract Rule

The canonical protocol definition must be raw JSON Schema artifacts stored in the repository.

Language-specific SDKs may generate or consume helpers from those artifacts, but they must not replace them as the source of truth.

## EasyTalk

`references/easy_talk` can still be useful on the Ruby side.

Allowed uses:

- defining an agent's optional global config schema
- defining an agent's optional per-conversation config schema
- validating Ruby-side config objects inside the agent implementation
- exporting advisory JSON Schema metadata for authoring help or future UI use

Disallowed use:

- defining canonical RPC method schemas

The protocol must not depend on Ruby-specific DSL behavior or partial JSON Schema compatibility.

## Transport

The protocol should be transport-neutral at the message level.

The method semantics should be stateless.

Each request must carry the context it needs.

Business state must live in Cybros models and run state, not inside a live connection.

Required v1 bindings:

- network transport for real deployments
- stdio adapter for local development, testing, and debugging

Recommended first network binding:

- WebSocket between Cybros and the registered `AgentDeployment`

All bindings should carry the same message model.

## Session Model

V1 should use bounded bidirectional sessions.

That means:

- one logical session may stay open for one lifecycle operation or one turn
- the agent may issue callbacks into Cybros public APIs during that bounded session
- the session ends when the operation returns, fails, or parks

The system should reopen a fresh session for later retry or resume work.

## Envelope

V1 should use a JSON-RPC-style envelope.

Core shapes:

- request: `jsonrpc`, `id`, `method`, `params`
- response: `jsonrpc`, `id`, `result`
- error response: `jsonrpc`, `id`, `error`
- notification: `jsonrpc`, `method`, `params`

Strict JSON-RPC 2.0 compatibility is less important than keeping the contract stable and recognizable.

## Versioning And Capabilities

The protocol must negotiate version and capabilities explicitly during initialization.

The handshake should surface at least:

- `protocol_version`
- `agent_sdk_version`
- `supported_methods`
- `capabilities`

Version or capability mismatch should fail fast with structured protocol errors instead of relying on best-effort compatibility.

## Bidirectional Model

The protocol should allow both sides to make requests.

That means:

- Cybros-side calls into the agent
- the agent can call back into Cybros public APIs over the same logical protocol

This is required because the agent is passive in the product model but still needs a controlled way to operate on the conversation.

Bidirectional does not mean permanent connection ownership by Rails.

V1 should prefer bounded logical sessions over a design where agent programs keep long-lived ambient ownership of the web app connection.

## Method Families

V1 should stay small and semantic.

### Session / Handshake

- `initialize`
- `agent.describe`
- `agent.health`
- `agent.schemas.get`

### Turn Hooks

- `turn.prepare`
- `turn.compose`
- `turn.handle_error`

`turn.prepare` operates on a mutable run-planning draft.

`turn.compose` and `turn.handle_error` operate on a materialized `ConversationRun`.

### Cybros Public APIs

- `conversation.settings.get`
- `conversation.settings.update`
- `conversation.config.get`
- `conversation.config.update`
- `conversation.kv.get`
- `conversation.kv.set`
- `conversation.kv.delete`
- `conversation.kv.list`
- `execution_target.propose`

## Method Direction

V1 should make method direction explicit.

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
- `conversation.kv.get`
- `conversation.kv.set`
- `conversation.kv.delete`
- `conversation.kv.list`
- `execution_target.propose`

## Turn Control Boundary

Turn hooks must stay declarative.

The agent may:

- return prompt fragments or workflow decisions
- request settings/config/KV mutations through public APIs
- propose an execution target

The agent must not:

- write DAG internals directly
- decide final tool policy
- bypass approval or retry/resume
- mutate run snapshots or system bookkeeping

Cybros remains authoritative for final prompt assembly, DAG mutation, tool-loop orchestration, policy merge, approval handling, and durable audit.

## Re-entry And Resume

Turn-scoped methods must be re-entrant.

Each turn-scoped request should carry stable identifiers such as:

- `run_draft_id`
- `conversation_run_id`
- `turn_id`
- `invocation_id`

`invocation_id` should act as the request idempotency key for that call attempt.

If Cybros retries or resumes work:

- it opens a fresh bounded session
- it sends a new request instead of reviving an old suspended one
- it includes explicit resume context when needed

The agent must not rely on transport continuity for correctness.

## Mutation Rules

The protocol should not expose `conversation.metadata.patch`.

The writable surfaces are:

- public conversation settings
- agent per-conversation config through dedicated config methods
- shared conversation KV
- execution target proposals

The protocol must never expose direct writes to:

- DAG internals
- system bookkeeping
- system-reserved state

## Approval Semantics

When an agent proposes switching execution targets and policy resolves to confirm, Cybros should block draft finalization.

That blocking must happen in runtime state, not by keeping an RPC request hanging forever.

The protocol should return a typed decision:

- `approved`
- `rejected`
- `awaiting_approval`

Then Cybros can park and later resume draft finalization through its own approval and retry mechanics.

This also means an approval wait should end the current protocol session cleanly before `ConversationRun` is materialized.

Resume should happen through a new invocation, not by reviving an old hanging request.

## Error Model

Protocol errors should be structured.

At minimum:

- `code`
- `category`
- `message`
- `retryable`
- `details`

This is required for:

- transport failures
- invalid config
- invalid method params
- unsupported capabilities
- approval-required responses
- unhealthy or unavailable `AgentDeployment`

## Registration Boundary

Deployment registration is outside the wire protocol.

V1 uses explicit operator-managed registration of `AgentDeployment` connection details.

Once registered, Cybros uses `initialize`, `agent.describe`, `agent.health`, and `agent.schemas.get` to inspect and validate that deployment.

## Schema Conventions

V1 should use a conservative JSON Schema profile.

Recommended conventions:

- prefer object results over bare scalars
- deny unknown properties unless explicitly allowed
- represent UUIDs as strings
- represent timestamps as RFC 3339 strings
- define params and results separately
- avoid advanced schema features without a strong need

## Relationship To Product Model

`agent_rpc` is part of the programmable-agent contract.

It exists to serve:

- `AgentProgram`
- `AgentDeployment`
- `Conversation`
- `ConversationRun`
- `ConversationKV`
- `ExecutionTarget`

It is not the Nexus protocol and should not inherit Conduits semantics.
