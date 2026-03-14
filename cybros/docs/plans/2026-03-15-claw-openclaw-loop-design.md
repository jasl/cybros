# Claw OpenClaw Loop Design

## Goal

Integrate the core OpenClaw-style agent loop capabilities into the bundled `claw` agent without prematurely turning `memory`, `web`, or `search` into Cybros-wide platform primitives.

The target is not full OpenClaw parity. The target is a credible validation path for two concrete workloads:

- `B`: coding/workspace loop
- `A`: personal-assistant loop

Delivery order is `B -> A`, but both phases must share the same agent-side capability spine.

## Context

Cybros already owns the durable execution model:

- DAG scheduling
- task/tool audit
- approvals and public-state mutation policy
- runtime identity and capability snapshots
- prompt assembly and context pressure hooks

What is still thin is the default bundled agent. The current `claw` host mainly contributes prompt text and hook-time prompt-buffer mutations. It does not yet expose agent-owned tools, workspace bootstrap semantics, or OpenClaw-style long-lived capability surfaces.

## Design Summary

Keep the runtime split explicit:

- Cybros owns orchestration, DAG state, policy, approvals, transcript state, and audit.
- `claw` owns the default-agent capability layer.

The bundled `claw` agent will become an agent-owned tool provider through `agent_tool_catalog + tool.execute`. This is the single spine used for both `B` and `A`.

Only `MEMORY` becomes conversation-owned state in V1. Other bootstrap inputs remain static or profile-driven:

- `AGENTS.md`: repo/workspace or bundled context
- `SOUL.md`: bundled default, later user-profile override
- `USER.md`: bundled default, later user-profile override
- `TOOLS.md`: synthesized from visible tool surface
- `MEMORY`: conversation-owned logical document

This avoids freezing Cybros into a premature memory platform while still letting the default agent behave like an OpenClaw-style assistant.

## Scope

### In Scope

- Add agent-owned tool support to bundled `claw`
- Make `claw` advertise a stable logical tool catalog
- Implement coding/workspace tools in `claw`
- Add a narrow callback surface for conversation-owned memory documents
- Rebuild `claw` prompt assembly around OpenClaw-style bootstrap sections
- Support user-scoped soft profiles on the agent side
- Validate `B` first, then `A`

### Out of Scope

- Rebuilding Cybros memory as a platform capability
- Browser automation
- Multi-channel routing
- Node/device tooling
- Strong security isolation by user
- Lane-local memory overlays

## Capability Model

### Phase B1: Coding / Workspace Tools

The first bundled `claw` tool catalog exposes stable logical names:

- `read`
- `write`
- `edit`
- `apply_patch`
- `glob`
- `search`
- `exec`

These are implemented by `claw`, not by the Cybros kernel registry.

The main validation target is a full coding loop inside the conversation workspace:

1. search files
2. read relevant files
3. edit or patch files
4. run commands
5. summarize results back into the main response

### Phase A1 / A2: Assistant Tools

The second wave extends the same agent-owned tool catalog:

- `memory_search`
- `memory_get`
- `memory_store`
- `web_search`
- `web_fetch`

These stay agent-owned in V1 even if their eventual long-term home is Cybros platform infrastructure.

## Prompt and Bootstrap Design

`claw` should stop behaving like a thin bundled prompt wrapper and start behaving like a compact system-prompt assembler.

### Main Session Prompt

Main sessions include:

- stable agent identity and guardrails
- workspace descriptor
- synthesized tool surface description
- injected bootstrap context
- conversation memory excerpt when relevant

### Subagent Prompt

Subagent runs use a smaller prompt mode and keep only the minimum bootstrap set:

- `AGENTS.md`
- synthesized `TOOLS.md`
- workspace descriptor
- safety/tooling sections

Subagents do not inject the full conversation memory body by default.

### Bootstrap Sources

Bootstrap inputs are split by ownership:

- bundled/repo/profile-owned: `AGENTS`, `SOUL`, `USER`, `TOOLS`
- conversation-owned: `MEMORY`

This preserves OpenClaw’s bootstrap pattern without forcing everything into per-conversation files.

## Memory Design

### Decision

`MEMORY` is a conversation-owned logical document.

It is not modeled as a workspace file source of truth in V1.

### Why

- conversation memory maps cleanly onto Cybros’ existing ownership model
- it avoids committing to a file-backed memory architecture that will likely be replaced
- it avoids lane-copy semantics and branch synchronization problems

### Contract

The agent sees a logical memory API:

- `conversation.memory.get`
- `conversation.memory.put`
- `conversation.memory.append`

The agent does not directly read or write `lane.kv`.

### Backing Store

The first implementation may use a namespaced backing on Cybros side, including a main-lane-backed implementation if that is the lowest-risk path, but this is explicitly an internal detail.

The agent contract is conversation-scoped, not lane-scoped.

### Branching Semantics

All lanes within a conversation share the same conversation memory document.

V1 does not support:

- lane-local memory
- copy-on-first-message memory inheritance
- parent-lane lazy memory cloning

This is intentional. It removes ambiguity and keeps the eventual platform migration simpler.

## User Profile Design

`user_id` is already present in session and execution context and should be used by `claw` as a soft profile key.

### Allowed Uses

- per-user `SOUL` / `USER` overrides
- search and web auth profile caches
- agent-side indexing caches
- future user-level preference material

### Non-Goals

This is not a tenant boundary and must not be treated as one.

No security or isolation guarantees are implied by user-scoped profile roots.

## Protocol Changes

### Agent Capabilities

Bundled `claw` must advertise:

- `tool.execute`
- non-empty `agent_tool_catalog`

This allows Cybros capability snapshot merging to route logical tools to agent-side implementations.

### Tool Execution

`tool.execute` remains the execution path for agent-owned tools.

For most tools, the request remains simple request/response.

### Callback Expansion

To support conversation-owned memory, `tool.execute` needs a narrow callback session.

The first allowed callback list should contain only:

- `conversation.memory.get`
- `conversation.memory.put`
- `conversation.memory.append`

This is the only intentional protocol expansion in V1.

### Complexity Constraint

The added callback surface is accepted as necessary implementation complexity. It should not block delivery.

The design does require a follow-up protocol review after implementation to see whether the surface can be reduced, generalized, or restructured.

## State Boundaries

Three state roots exist in the design:

### Conversation Scope

Owned by Cybros conversation identity:

- logical workspace
- attachments
- conversation memory logical document

### User Profile Scope

Owned by agent-side soft profile identity:

- per-user profile files
- cached indexes
- web/search credentials or preferences

### Run Temp Scope

Owned by one turn/run only:

- temp files
- search scratch data
- ephemeral render/index state

Only conversation scope is authoritative for `MEMORY` in V1.

## Implementation Phases

### Phase B1

Add agent-owned tool catalog and implement the coding/workspace loop:

- stable tool catalog
- tool routing into `claw`
- workspace bootstrap
- coding tools
- DAG-visible execution and audit

### Phase A1

Add conversation-owned memory document support:

- callback contract
- agent-side memory tools
- prompt integration for memory excerpts

### Phase A2

Add web/search and OpenClaw-style loop support:

- `web_search`
- `web_fetch`
- silent housekeeping
- pre-compaction memory flush

## Testing Strategy

### Protocol Tests

- bundled `claw` advertises `tool.execute`
- capability handshake persists non-empty agent tool catalog
- `tool.execute` supports callback sessions with a strict whitelist

### B1 Integration Tests

Validate a workspace loop end-to-end:

- search within the conversation workspace
- read a file
- apply an edit or patch
- run a command
- observe standard DAG tool activity and final reply

### A1 Integration Tests

Validate conversation-owned memory:

- “remember this” writes to conversation memory
- later turns can query it with `memory_search` / `memory_get`
- branch lanes see the same memory without any copy step

### A2 Integration Tests

Validate assistant loop features:

- `web_search` / `web_fetch` work when configured
- context pressure can trigger silent memory flush
- subagent minimal prompt does not inject full conversation memory

## Risks

### Callback Protocol Growth

Expanding `tool.execute` to support callbacks increases protocol complexity.

Accepted in V1. Mitigation is a narrow whitelist and a post-implementation review.

### Hidden Lane Coupling

If the backing implementation uses lane-backed storage carelessly, conversation memory could accidentally become lane memory.

Mitigation: the public contract and tests must stay conversation-scoped.

### User Profile Misinterpretation

Developers may treat `user_id`-scoped storage as an isolation boundary.

Mitigation: document clearly that it is only agent-side namespacing.

## Completeness Check

This design now has explicit answers for the main implementation blockers:

- where `A` and `B` connect: shared agent-owned tool spine
- delivery order: `B -> A`
- memory ownership: conversation-owned logical document
- branch behavior: shared conversation memory, no copy-on-first-message
- user profile semantics: soft namespacing only
- protocol expansion: allowed and intentionally narrow
- prompt model: OpenClaw-style bootstrap sections with minimal subagent mode

The remaining intentionally deferred decisions are post-V1 concerns:

- whether conversation memory backing should later move to a first-class Cybros model
- whether user-profile state should become a supported platform abstraction
- whether `tool.execute` callback shape should later be generalized beyond memory

Those are valid follow-up questions, but they do not block the validation work defined here.
