# Migration Alignment

This document maps the current codebase to the programmable-agent target architecture.

As of the 2026-03-10 programmable-agent rebaseline, it is a status snapshot of what is now aligned. Fresh mismatches should be recorded in current audit documents, not inferred from stale pre-cutover gap lists.

## Current Alignment

### 1. Conversation Runtime Selection Is First-Class

Current state:

- top-level conversations persist `agent_program_id`, `default_execution_target_id`, and `permission_mode`
- the default interactive path resolves model preference, input policy, and runtime surface from `Conversation.agent_program` and the published manifest snapshot
- `conversations.metadata["agent"]` is no longer the top-level interactive authority; it remains only for explicit legacy `agent_profile` compatibility rows and subagent child worker payloads
- top-level interactive runtime resolution does not fall back to a local builtin provider when no `ConversationRun` exists

Target state:

- keep conversation-scoped runtime selection on first-class fields
- keep metadata-only runtime authority limited to explicit legacy and child-worker compatibility paths

### 2. Draft And Run Semantics Are Split

Current state:

- `RunDraft` is the mutable planning record
- `ConversationRun` is the immutable execution record
- `RunDraft` pins program, contract, deployment, execution target, provider, runtime governors, and `agent_config_schema_fingerprint`
- finalization materializes `ConversationRun` from the pinned draft binding instead of re-reading mutable conversation defaults

Target state:

- preserve the draft/run split
- preserve draft-pinned finalization for approval resume, stale detection, and replay safety

### 3. `AgentProgram` And `AgentDeployment` Have Distinct Authority

Current state:

- `AgentProgram` is the selectable identity and canonical contract owner
- `AgentDeployment` is the reachable runtime binding with explicit registration, inspection, activation, and health
- planning resolves the active healthy deployment that matches the selected program's published contract

Target state:

- keep `AgentProgram` as product identity and contract owner
- keep `AgentDeployment` as runtime connectivity and health

### 4. Source Ownership Is Explicit

Current state:

- bundled agent sources live under `agents/` in the app repository
- custom agent sources live under the operator-configured agent workspace root
- the custom-agent workspace root must be explicit, absolute, and outside the Cybros app repository
- outside test, Cybros does not silently default custom-agent workspace roots to `Rails.root`

Target state:

- keep bundled and custom source ownership separate
- keep custom source material outside the app repository

### 5. Planning And Approval Resume Follow One Canonical Loop

Current state:

- conversations and automations converge on `RunDraft -> finalization -> immutable run`
- approval parking preserves the prepared draft without materializing a partial run
- resumed finalization validates the pinned binding instead of silently drifting to later conversation-level changes

Target state:

- keep planning, approval resume, and execution on the same canonical lifecycle
- reject stale bindings explicitly instead of reintroducing hidden fallback paths

### 6. Runtime Governance Is First-Class

Current state:

- provider credentials, runtime settings, execution locations, workspaces, execution targets, waits, leases, and reservations are modeled explicitly
- draft planning and finalization snapshot runtime-governor facts into the immutable run record

Target state:

- keep runtime governance explicit and durable
- keep admission recovery and capacity waits on product-owned primitives

## How To Use This Document

- use the product docs under `docs/product/` as the source of truth for current architecture
- use current audits for fresh findings
- do not treat this file as a backlog of historical pre-rebaseline gaps
