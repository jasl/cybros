# State Taxonomy

This document defines the storage classes in the product model.

The goal is to stop product state from collapsing back into generic `metadata`.

## Agent Global Config

Purpose:

- operator-managed configuration shared by an `AgentProgram` across conversations and automations

Examples:

- integration defaults
- account-level feature switches
- program-wide behavior flags

Rules:

- stored under the owning `AgentProgram`
- versioned by the published contract fingerprint
- not writable through ordinary conversation-scoped runtime APIs
- distinct from per-conversation config and lane-scoped mutable state

## Conversation Runtime Defaults

Purpose:

- durable conversation-scoped runtime selection that defines how future turns start

Examples:

- top-level `agent_program_id`
- `permission_mode`
- `default_execution_target_id`

Rules:

- stored as first-class conversation fields, not public settings entries
- writable through dedicated conversation-setting surfaces
- affect future drafts and runs only
- snapshotted into `RunDraft` and `ConversationRun`
- do not retroactively rewrite an already running or parked turn

## Public Conversation Settings

Purpose:

- durable product-facing conversation configuration

Important boundary:

- conversation-scoped runtime defaults such as `agent_program_id`, `default_execution_target_id`, and `permission_mode` are first-class conversation fields, not entries inside public settings

Examples:

- title
- default model preference
- active persona or mode

Rules:

- writable by user
- writable by agent through public APIs
- policy-gated
- typed
- audited
- not used as general KV

## Agent Per-Conversation Config

Purpose:

- structured config for the selected agent program within one conversation

Examples:

- persona tuning
- workflow defaults
- feature toggles

Rules:

- stored as agent-owned JSON in v1
- writable through public APIs only
- durable
- audited
- not a general runtime-state bucket
- interpreted as namespaced by agent-program contract so switching the top-level conversation agent does not require clearing unrelated config
- versioned against the published contract fingerprint for the selected program

V1 may enforce only light schema validation, but the contract fingerprint still matters for snapshot and migration semantics.

## Lane KV

Purpose:

- branch-local operational working state for agents inside one lane

Examples:

- workflow variables
- checkpoints
- pending subtasks
- namespaced agent-private state

Rules:

- scoped to one lane snapshot
- JSON values
- writable by agent through public APIs
- current-state only in v1
- not used for long-term retrieval
- no implicit TTL in v1

## Lane Prompt Buffer

Purpose:

- branch-local prompt working material for one lane

Examples:

- summaries
- working notes
- handoff material

Rules:

- scoped to one lane snapshot
- ordered and token-aware
- writable by agent through public APIs
- prompt-side working set only
- not durable transcript history
- not general structured KV

## Memory

Purpose:

- retrievable durable information for agent reasoning

Examples:

- user preferences worth recalling later
- durable facts extracted from conversation
- important run outcomes

Rules:

- retrieval-oriented
- distinct from lane KV and lane prompt buffer
- built-in baseline plus adapter-friendly
- explicit scope and visibility rules are required
- may be searchable
- writes remain policy-aware and auditable
- canonical retrieval results should be citation-friendly rather than opaque blobs

## Knowledge

Purpose:

- imported or curated information sources outside the active conversation

Examples:

- uploaded docs
- repo docs
- indexed corpora

Rules:

- source-oriented
- usually read-mostly
- searchable and citation-friendly
- may be built-in or adapter-backed
- not writable as arbitrary runtime state

Static prompt injections are one implementation technique, not the whole knowledge model.

## Run Snapshot

Purpose:

- immutable execution record for one run

Examples:

- agent program id
- contract fingerprint
- agent deployment id
- deployment fingerprint
- deployment activation epoch
- execution target
- selected model
- effective public settings
- effective `agent_config`
- effective policy profile

Rules:

- immutable after finalization
- durable
- auditable
- never reused as mutable settings state

## Automation Dispatch Facts

Purpose:

- immutable automation-trigger facts for one execution `Conversation`

Examples:

- originating `automation_id`
- `dispatch_key`
- scheduled trigger facts
- original task payload prompt or selected model when needed for audit

Rules:

- immutable after dispatch
- live on the execution `Conversation` lineage and any derived `RunDraft` / `ConversationRun` snapshots, not as a second run record
- durable and auditable

## System State

Purpose:

- internal runtime bookkeeping

Examples:

- DAG nodes and edges
- stream cursors
- queue bookkeeping
- internal policy decisions
- transport recovery markers
- run drafts
- agent RPC sessions, invocations, and operation receipts
- provider budget reservations
- execution capacity leases
- runtime waits

Rules:

- not directly writable by agents
- internal services only
- not part of the public programmable surface

## Summary Rule

Use the smallest correct storage class:

- global agent config for program-scoped operator configuration
- settings for product configuration
- per-conversation config for agent-owned JSON configuration
- KV for operational variables
- memory for retrievable durable facts
- knowledge for external or curated sources
- run snapshots for immutable audit
- system state for internals only
