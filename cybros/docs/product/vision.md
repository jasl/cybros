# Vision

## Positioning

Cybros is the control plane for agent conversations.

The product model is intentionally small:

- `Conversation`
- `Agent`
- `RecognizedDeployment`

`Conversation` is the user-facing durable thread. `Agent` is the configured runtime endpoint and policy anchor. `RecognizedDeployment` is the observed runtime identity that pins a specific turn.

## Product Principles

- `Conversation -> Agent -> RecognizedDeployment` is the canonical runtime path.
- The dashboard launches new conversations from explicit agent rows; generic agent-less "new chat" entry points are retired.
- Agent upgrades affect future turns only. Historical drafts and runs stay pinned to the recognized runtime identity captured when they were created.
- Runtime policy belongs to `Agent`, especially execution capacity.
- The bundled/default agent path now uses an agent-owned root workspace, with each conversation receiving a lightweight working directory under that root.
- Lane-local state stays hidden under `.lanes/<lane_id>/` unless the current branch actually needs it.
- Uploaded files are first-class conversation artifacts and move into agents through explicit import/transfer steps, not raw RPC byte payloads.
- Product flows should hide obsolete runtime topology such as deployment activation inventories or execution-target switching.

## Non-Goals For V1

- user-facing multi-agent switching inside one conversation
- user-facing deployment inventory management
- user-facing execution-target/location/workspace topology
- strong attestation that agent-reported runtime metadata is truthful
- compatibility layers that preserve the abandoned pre-cutover runtime mental model
