# Cybros Product Docs

This directory holds the active product contract for the simplified conversation-agent runtime.

Current reading order:

1. `vision.md`
2. `runtime_governance.md`
3. `agent_rpc.md`
4. `docs/plans/2026-03-13-conversation-agent-runtime-simplification-design.md`
5. `docs/plans/2026-03-16-agent-root-workspace-design.md`
6. `docs/plans/2026-03-17-operation-sequence-cutover-design.md`

Historical pre-cutover product docs were intentionally removed. Use git history if that material is still needed for archaeology.

## Core Invariants

- `Conversation` is the durable user-visible unit and always binds to one `Agent`.
- `Agent` is the user-visible runtime selector and owns runtime defaults plus execution-capacity policy.
- `RunDraft` and `ConversationRun` bind to one `RecognizedDeployment` so historical turns stay pinned when an agent changes later.
- The dashboard is the primary launcher: users start from an `Agent`, then create a `Conversation`.
- Automations bind to `Agent`, not to a deployment or execution target inventory object.
- Each `Agent` owns one durable root workspace, and each `Conversation` gets a lightweight working directory beneath that root.
- Lane-local state lives under `conversations/<conversation_id>/.lanes/<lane_id>/` and stays hidden from normal workspace browsing unless the lane actually uses it.
- Attachments are stored through Active Storage and transferred into agents through `attachments.import` plus an explicit transfer task.
- Breaking changes are allowed when they reduce product-path complexity and remove obsolete runtime surfaces.
