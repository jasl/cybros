# Agent RPC

## Definition

`agent_rpc` is the wire contract between Cybros and an `Agent` runtime endpoint.

Current bundled implementation: `claw` at `cybros/agents/claw`.

The configured `Agent` is the user-visible selector. At runtime Cybros performs initialization/handshake, observes a runtime identity, and resolves or creates a `RecognizedDeployment` for turn-level pinning.

## Core Rules

- Cybros owns planning, policy, approval, finalization, transcript state, and audit state.
- Agents are bounded runtimes, not peer control planes.
- One turn binds to one recognized runtime identity. If that identity drifts, the turn must fail safe instead of silently continuing.
- Attachment transfer is descriptor-based: Cybros sends signed download URLs and the agent imports them through `attachments.import`.

## Current Hook Surface

Shipped hook and capability methods:

- `capabilities.handshake`
- `capabilities.refresh`
- `attachments.import`
- `on_conversation_created`
- `on_lane_first_user_message`
- `before_agent_step`
- `on_context_pressure`
- `before_subagent_spawn`
- `after_task_notice`
- `after_subagent_result`
- `before_finalize_output`
- `tool.execute`
- `tool_surface.manifest`

The bounded callback surface available to agents includes:

- `conversation.settings.*`
- `conversation.config.*`
- `lane.kv.*`
- `lane.prompt_buffer.*`
- `tokens.*`
- `tool_surface.manifest`

## Authentication And Sessions

- Cybros calls the agent's configured endpoint with the deployment bearer secret.
- Initialization and handshake must return identity data consistent with the configured binding.
- After initialization, Cybros mints a short-lived callback session bearer for bounded callbacks into kernel services.
- Sessions are authorization artifacts, not the durable identity of a logical hook invocation.

## Runtime Artifacts

The protocol persists three internal runtime artifacts:

- `agent_rpc_session`
- `agent_rpc_invocation`
- `agent_rpc_operation_receipt`

These are system-state records for replay, callback authorization, and audit. They are not product-facing objects.

## Attachment Import

`attachments.import` is the upload bridge from Active Storage attachments into agent-consumable references.

Request descriptors include:

- attachment id
- filename
- content type
- byte size
- digest
- signed download URL

The agent responds with one imported remote reference per attachment. Raw bytes do not ride inside the RPC request body.
