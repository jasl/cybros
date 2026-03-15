# Agent Root Workspace Design

## Status

Approved design notes for replacing Cybros' conversation-owned logical workspace and lane-kv memory with an agent-root workspace model closer to OpenClaw.

This is an intentionally breaking cutover. Compatibility layers and data migration are out of scope. Existing conversation-owned workspace and logical-memory behavior should be removed rather than preserved.

## Goal

Move the bundled/default agent path to an agent-owned root workspace where:

- one `Agent` owns one durable root workspace
- all conversations under that `Agent` share the same top-level bootstrap files
- each conversation gets a lightweight working directory under that root
- each lane gets an optional hidden local state directory under its conversation
- memory becomes file-backed truth (`MEMORY.md` plus optional `memory/*.md`) instead of lane kv

The design target is not to turn Cybros into a second OpenClaw runtime. Cybros still owns DAG scheduling, approvals, transcript durability, and subagent execution. The change is about workspace ownership, memory shape, and prompt/bootstrap behavior.

## Context

Current shipped product/runtime docs still encode these assumptions:

- each conversation owns one persistent logical workspace
- bundled `claw` bootstraps prompt sections from bundled prompt files plus a conversation-backed logical memory document
- conversation memory is stored behind callback methods and backed by lane kv

That model matched the earlier runtime simplification phase, but it now conflicts with the more credible OpenClaw-style operating model:

- durable agent identity and guidance should live in a long-lived agent workspace
- conversations under the same agent should share top-level durable files
- lane/session memory should be allowed without making every lane a full independent workspace
- bootstrap files should be copied into a live workspace once and then become editable runtime truth

## Design Summary

Replace conversation-owned workspaces with a three-scope workspace model:

- `root` scope: agent-owned, shared across all conversations and lanes under the same `Agent`
- `conversation` scope: lightweight working directory for one conversation
- `lane` scope: hidden local state directory under one conversation, created only when needed

Memory also becomes three-scope:

- `root/MEMORY.md` and `root/memory/*.md`
- `conversation/MEMORY.md` and `conversation/memory/*.md`
- `lane/MEMORY.md` and `lane/memory/*.md`

Prompt/bootstrap behavior becomes more conservative than the file layout:

- automatically inject root bootstrap files and a small scope inventory
- do not automatically inject full conversation or lane memory bodies
- use `memory_search/get/store` as the primary way to read and write scoped memory

The core runtime split remains strict:

- Cybros owns loop progression, DAG execution, approvals, transcript state, and audit
- bundled `claw` owns workspace-oriented tools, memory tools, and prompt assembly

## Scope

### In Scope

- destructive replacement of conversation-owned logical workspaces with agent-root workspaces
- destructive replacement of lane-kv memory with file-backed memory files
- bundled prompt seeding into live agent workspaces
- bundled skill seeding into live agent workspaces
- explicit three-scope memory semantics: root, conversation, lane
- hidden lane directories under conversations
- agent-local mutable skills under the live agent root
- agent-side self-mutate workflow for `SOUL.md`, `USER.md`, and agent-local skills
- prompt/bootstrap changes needed to keep the new directory model usable by real LLMs
- live acceptance tests against a real model, not only mocks

### Out of Scope

- preserving old workspace or memory records
- keeping conversation-owned workspace metadata for compatibility
- turning DAG state into file-backed truth
- making lanes first-class user-visible filesystem roots
- allowing live mutation of `AGENTS.md`
- symlink-based live overlays for bootstrap or skill files
- strong multi-user filesystem isolation guarantees
- browser/device/channel behaviors unrelated to workspace and memory ownership

## Ownership Model

### Agent Owns The Workspace

Each `Agent` owns one durable root workspace.

Recommended path model:

- configured base directory: `RuntimeSetting.agent_workspace_root`
- default base value: `~/.cybros/agents`
- concrete bundled `claw` root: `<base>/claw-<agent_id>`

The root workspace is materialized on first real use of the `Agent`, not at boot.

### Conversation Is A Working Subdomain

`Conversation` no longer owns a top-level workspace identity.

Instead, it owns a lightweight subdirectory under the agent root:

- `conversations/<conversation_id>/`

This directory is the default `cwd` for ordinary coding/file tasks in that conversation.

### Lane Is A Hidden Local Scope

Lane-local state lives under the conversation directory:

- `conversations/<conversation_id>/.lanes/<lane_id>/`

This keeps lane ownership aligned with Cybros semantics:

- a lane is a conversation-internal execution branch
- lane state should not dominate normal workspace browsing
- lane-local state should be easy to delete/archive with the parent conversation

The `.lanes` prefix intentionally hides lane-local files from most normal directory scans.

## Workspace Topology

The target layout is:

```text
<agent-root>/
  AGENTS.md
  SOUL.md
  USER.md
  MEMORY.md
  skills/
    self-mutate/
      SKILL.md
      scripts/
      references/
      assets/
  memory/
    YYYY-MM-DD.md
  .history/
    soul/
    user/
    skills/
  conversations/
    <conversation_id>/
      MEMORY.md
      memory/
        YYYY-MM-DD.md
      attachments/
      artifacts/
      scratch/
      .lanes/
        <lane_id>/
          MEMORY.md
          memory/
            YYYY-MM-DD.md
          working-notes.md
          state.json
```

This is a semantic topology, not an eager materialization contract.

V1 should create directories lazily:

- root files are seeded when the agent root is first materialized
- `skills/` is seeded only when bundled/default agent skills exist
- `.history/` appears only when the first mutable bootstrap or skill change is written
- `conversations/<conversation_id>/` appears only when the conversation first needs filesystem state
- `.lanes/<lane_id>/` appears only when the lane first needs lane-local memory or other lane-local state
- `MEMORY.md` and `memory/` at conversation/lane scope are created only when first written

## Bootstrap Source Of Truth

Bundled prompt files under `cybros/agents/claw/prompts/*` stop being the live runtime truth after bootstrap.

They become seed templates only.

On first agent-root materialization, Cybros copies the bundled defaults into the live root workspace:

- `AGENTS.md`
- `SOUL.md`
- `USER.md`
- empty or starter `MEMORY.md`
- bundled `skills/*` when bundled/default skills exist
- `memory/`

After that:

- the live workspace files are the source of truth
- the agent program reads from the live workspace, not directly from bundled prompt files
- the agent program reads agent-local skills from the live root, not only from bundled source directories
- changing the bundled source later does not silently rewrite existing agent roots

This preserves the OpenClaw bootstrap pattern without forcing runtime personalization to modify bundled source code.

## Agent-Local Skills

### Layering

Skills are split into two layers:

- platform skills: provided by Cybros infrastructure
- agent-local skills: live under `<agent-root>/skills/` and belong to one `Agent`

This keeps the responsibility split clear:

- Cybros provides the generic skills infrastructure and built-in capabilities
- bundled `claw` decides how to compose its business-specific workflows on top of that infrastructure

### Agent-Local Skill Root

The live source of truth for agent-local skills is:

- `<agent-root>/skills/<skill_name>/SKILL.md`

Optional subdirectories follow the existing skills contract:

- `scripts/`
- `references/`
- `assets/`

Bundled/default agent skills may be seeded into that directory once, then become live editable files.

### Merge And Conflict Rules

Prompt assembly and `skills_*` tools should expose the merged set of:

- platform skills
- agent-local skills

Name collisions must fail closed.

V1 rule:

- an agent-local skill may not override a platform skill with the same name
- startup or runtime refresh should surface a stable error instead of silently picking a winner

### Mutable Scope

V1 allows the agent to create and modify:

- `root/SOUL.md`
- `root/USER.md`
- `root/skills/**`
- `root/.history/**`

V1 does not allow the agent to modify:

- `root/AGENTS.md`
- Cybros platform skill source directories
- any path outside the resolved agent root

### Why `AGENTS.md` Stays Read-Only

`SOUL.md` and `USER.md` belong to the mutable agent-owned guidance layer.

`AGENTS.md` belongs to the operator/platform contract layer:

- workspace semantics
- tool-use guardrails
- runtime structure facts

Letting the agent rewrite that file would blur the line between mutable guidance and the platform contract, and would make it much easier for the prompt surface to drift away from real runtime behavior.

## Memory Model

### Root Memory

`root/MEMORY.md` is the agent-shared curated memory.

It is appropriate for:

- stable preferences
- long-lived identity and collaboration norms
- durable knowledge shared across many conversations

`root/memory/YYYY-MM-DD.md` is the append-only log at root scope.

### Conversation Memory

`conversations/<conversation_id>/MEMORY.md` is topic-level durable memory for that conversation family.

It is appropriate for:

- project-specific conventions
- durable conclusions for the ongoing thread/topic
- context worth carrying into branched follow-up conversations

`conversation/memory/YYYY-MM-DD.md` is the append-only log at conversation scope.

### Lane Memory

`conversations/<conversation_id>/.lanes/<lane_id>/MEMORY.md` is lane-local/session-local memory.

It is appropriate for:

- local working hypotheses
- active subtask notes
- compaction handoff notes
- transient or semi-durable state that should not immediately contaminate broader scopes

`lane/memory/YYYY-MM-DD.md` is the append-only log at lane scope.

## Read And Write Policy

`memory_search` defaults to searching in this order:

1. current lane
2. current conversation
3. root

Every result must expose:

- `scope`
- `path`
- `line`
- `snippet`

`memory_get` reads a specific scope and target. It should not silently fall back to another scope.

`memory_store` defaults to:

- `scope=lane`
- `mode=append`

This is the safest default because it prevents local noise from polluting shared scopes.

Writing to `conversation` or `root` must be explicit.

## Upward Memory Sync Timing

The timing of promoting memory upward is part of the design, not an incidental implementation detail.

### Non-Goal

Do not auto-promote memory on every turn.

That would quickly pollute shared scopes and make the model's mistakes durable.

### Lane To Conversation Promotion

Lane-local memory may be promoted upward at specific lifecycle points, modeled after the useful parts of OpenClaw's flush behavior:

- before context compaction when the runtime signals pressure
- when a lane is being ended or handoffed in a way that would otherwise strand durable conclusions inside lane-local files
- immediately before branching into a new conversation from a lane when the branch should inherit the lane's durable conclusions

The runtime should trigger a silent flush/promotion opportunity at those moments.

The agent still performs the actual write through normal memory tools. The system does not invent a hidden side channel that bypasses tool semantics.

Default promotion target:

- lane flush -> `conversation/memory/YYYY-MM-DD.md`

If the agent wants to curate that into `conversation/MEMORY.md`, that must be an explicit write decision.

### Conversation To Root Promotion

Conversation-to-root promotion is more conservative.

It should not happen automatically during ordinary compaction or ordinary lane completion.

Allowed promotion moments:

- explicit agent write to `scope=root`
- explicit user instruction
- optional future archive/close workflow if Cybros later introduces a deliberate "promote durable takeaways to shared root memory" action

Default V1 rule:

- no automatic conversation -> root promotion

This keeps the shared root cleaner and closer to true long-lived memory.

## Prompt And Bootstrap Design

The file topology is three-scope, but prompt injection should stay narrow.

### Main Session Prompt

Main session prompt assembly should include:

- root `AGENTS.md`
- root `SOUL.md`
- root `USER.md`
- synthesized `TOOLS.md`
- a workspace descriptor
- current date/time and runtime summary
- a small scope inventory
- merged available-skills inventory from platform and agent-local skills
- optionally a short root `MEMORY.md` excerpt under the existing bootstrap budget

The scope inventory should be tiny and explicit, for example:

- current root path
- current conversation path
- current lane path
- whether each scope currently has `MEMORY.md`
- whether each scope has today's `memory/YYYY-MM-DD.md`

### Conversation And Lane Memory Injection

Conversation and lane memory bodies should not be auto-injected wholesale.

Reasons:

- it keeps prompt pressure predictable
- it reduces accidental leakage of lane-local noise into every model request
- it nudges the model to use dedicated memory tools rather than blindly reading hidden directories

### Delegated/Subagent Prompt

Delegated runs continue to use minimal prompt mode.

They should not automatically receive full memory bodies from any scope.

At most they receive:

- minimal root bootstrap
- current workspace descriptor
- current scope inventory

### Skills Prompting

Skills should continue to follow the progressive-disclosure model:

- inject only the available-skills inventory by default
- load skill bodies on demand through `skills_load` / `skills_read_file`

This applies equally to platform and agent-local skills.

## Lifecycle And Branching

- agent root materializes on first real use of the agent
- conversation directory materializes on first conversation-local filesystem or memory write
- lane directory materializes on first lane-local filesystem or memory write

Default `cwd` for normal tool work:

- `conversations/<conversation_id>/`

Not:

- the agent root
- the hidden lane directory

This keeps ordinary coding/file tasks simple.

## Lane Creation

When a new lane is created inside a conversation:

- root scope is shared
- conversation scope is shared
- lane scope starts empty
- `.lanes/<lane_id>/` is not created until needed

## Branching To A New Conversation

When branching into a new conversation:

- the new conversation stays under the same `Agent` root
- Cybros creates a new `conversations/<new_conversation_id>/`
- Cybros snapshots the parent conversation's `MEMORY.md` into the child conversation's `MEMORY.md`
- Cybros does not copy `.lanes/`
- Cybros does not copy conversation/lane daily logs by default
- Cybros does not copy `scratch/`, artifacts, or materialized attachments by default

This is intentionally a copy, not a live link.

The copy gives the new branch the durable topic memory without dragging forward all lane-local or append-only noise.

If the branch is created from a live lane that may contain unsynced durable conclusions, the runtime should first offer the lane->conversation promotion window described above, then perform the snapshot copy.

## Deletion And Cleanup

- deleting or archiving a conversation removes its conversation directory and nested `.lanes/`
- deleting or resetting an agent removes the whole agent root
- V1 does not perform automatic lane GC

## Tool Contract

Memory files are source of truth, but memory tools are the controlled API surface.

### `memory_search`

Inputs:

- `query`
- optional `scopes`

Behavior:

- search scopes in deterministic order
- return source-aware matches
- set `truncated=true` when result caps apply

### `memory_get`

Inputs:

- `scope`
- optional `target`

Default target by scope:

- `root` -> `MEMORY.md`
- `conversation` -> current conversation `MEMORY.md`
- `lane` -> current lane `MEMORY.md`

### `memory_store`

Inputs:

- `content`
- optional `scope`
- optional `mode=append|replace`

Defaults:

- `scope=lane`
- `mode=append`

### File Tools Versus Memory Tools

Ordinary file tools remain available.

But the prompt and tool guidance should explicitly steer the model to use `memory_*` first for durable memory operations instead of directly editing hidden memory files with generic file tools.

This gives Cybros one stable place to enforce:

- scope validation
- path validation
- later approval rules
- later observability

## Mutable Bootstrap And Skill Writes

V1 does not add a dedicated self-mutate RPC tool.

Instead:

- self-mutate is expressed as an agent-local skill
- the skill orchestrates existing file tools and optional shell helpers
- the actual write authority stays inside the normal workspace/file execution surface

### Confirmation Rules

Writes to the following paths must always require confirmation, regardless of broader conversation permission mode:

- `root/SOUL.md`
- `root/USER.md`
- `root/skills/**`

This keeps the mutable agent-owned layer reviewable even when ordinary coding/file operations are broadly allowed.

### Write Workflow

The intended self-mutate workflow is:

1. read current file content
2. prepare new content or patch
3. generate a diff for user review
4. wait for confirmation
5. copy the previous file into `.history/`
6. write the new file
7. report the live path and snapshot path

V1 should not rely on symlink-based overlay switching for live bootstrap or skill files.

## Failure Modes

### Logical Scope Exists But Files Do Not

If a scope exists logically but its files have not been materialized yet:

- `memory_get` and `memory_search` should return a stable empty/not-materialized result, not a generic filesystem crash
- `memory_store` should materialize the needed directory/file on first write

### Invalid Scope

Return a stable domain error such as:

- `claw.memory.invalid_scope`

### Path Escape

Any attempt to write outside the resolved scope root must hard-fail at the agent host boundary.

This is not optional prompt discipline.

### Branch Snapshot Failure

If the conversation-memory snapshot for branch creation fails:

- branch creation fails as a whole
- Cybros does not leave a half-initialized child conversation pretending the snapshot succeeded

### Mutable Skill Name Collision

If an agent-local skill name conflicts with a platform skill name:

- fail closed
- surface a stable error
- do not silently override either skill

### Read-Only Bootstrap Mutation Attempt

If the agent attempts to mutate `AGENTS.md` through self-mutate workflows:

- deny the write
- surface a stable error explaining that `AGENTS.md` is read-only in V1

## Validation Strategy

This design must be validated with a real LLM, not only deterministic tests.

### Contract Tests

Add deterministic tests for:

- agent-root path derivation and materialization
- lazy conversation/lane directory creation
- hidden `.lanes` behavior
- agent-local skill seeding and discovery
- fail-closed skill-name collision handling
- memory tool scope rules
- lane->conversation promotion hooks
- branch snapshot copy of conversation `MEMORY.md`
- no automatic conversation->root promotion
- protected write boundaries for `SOUL.md`, `USER.md`, `skills/**`, and `AGENTS.md`

### Live Acceptance

Run real-model acceptance scenarios with a usable LLM backend.

Minimum required scenarios:

1. root shared memory
2. conversation isolation
3. lane-local memory isolation
4. branch snapshot inheritance
5. directory-complexity tolerance
6. compaction durability and lane flush behavior
7. self-mutate `SOUL.md`
8. self-mutate `USER.md`
9. create a new agent-local skill
10. modify an existing agent-local skill with `.history/` snapshot creation
11. failed attempt to modify `AGENTS.md`

Required live-test rule:

- do not rescue the model mid-run with manual instructions such as "open the hidden lane directory"

The model must succeed using only the shipped bootstrap prompt, tool surface, and workspace defaults.

### Acceptance Bar

Each live scenario should pass at least three consecutive times before the design is considered validated.

## Final Decisions

- `Agent` owns the durable root workspace
- `Conversation` owns a lightweight subdirectory, not a full top-level workspace identity
- `Lane` owns optional hidden local state under `.lanes/<lane_id>`
- root/conversation/lane memory are all file-backed truth
- bundled prompt files are seed templates, not live runtime truth after bootstrap
- bundled skills are seed templates, not live runtime truth after bootstrap
- agent-local mutable skills live under `root/skills/`
- platform and agent-local skills are merged, but name conflicts fail closed
- `memory_store` defaults to lane scope
- lane->conversation promotion happens only at explicit lifecycle points
- conversation->root promotion is never automatic in V1
- branching snapshots parent conversation `MEMORY.md` into the child conversation
- self-mutate is implemented as an agent-local skill, not a dedicated self-mutate RPC tool
- `SOUL.md`, `USER.md`, and `skills/**` are mutable but always confirmation-gated
- `AGENTS.md` remains read-only in V1
- live bootstrap and skill files use ordinary files plus `.history/`, not symlink overlays
- Cybros keeps loop authority; only workspace and memory ownership move toward the OpenClaw pattern
