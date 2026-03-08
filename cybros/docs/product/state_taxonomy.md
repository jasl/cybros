# State Taxonomy

This document defines the storage classes in the product model.

The goal is to stop product state from collapsing back into generic `metadata`.

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
- feature toggles
- workflow defaults

Rules:

- stored as agent-owned JSON in v1
- writable through public APIs only
- durable
- audited
- not a general runtime-state bucket
- interpreted as namespaced by agent-program contract so switching the top-level conversation agent does not require clearing unrelated config

The agent may publish a schema for authoring help or future validation, but Cybros does not strongly enforce that schema in v1.

## Conversation KV

Purpose:

- operational working state for agents inside one conversation

Examples:

- workflow variables
- checkpoints
- pending subtasks
- namespaced agent-private state

Rules:

- shared across agent switches in v1
- JSON values
- writable by agent through public APIs
- current-state only in v1
- not used for long-term retrieval
- no implicit TTL in v1

Reserved or recommended prefixes:

- `system.*` reserved and non-agent-writable
- `agent.<agent_key>.*`
- `shared.*`
- `user.*`

## Memory

Purpose:

- retrievable durable information for agent reasoning

Examples:

- user preferences worth recalling later
- durable facts extracted from conversation
- important run outcomes

Rules:

- retrieval-oriented
- distinct from conversation KV
- may be searchable
- writes remain policy-aware and auditable

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
- not writable as arbitrary runtime state

## Run Snapshot

Purpose:

- immutable execution record for one run

Examples:

- agent program id
- agent deployment id
- deployment fingerprint
- deployment activation epoch
- execution target
- selected model
- effective public settings
- effective `agent_config`
- `agent_config` schema fingerprint
- effective policy profile

Rules:

- immutable after finalization
- durable
- auditable
- never reused as mutable settings state

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

- settings for product configuration
- per-conversation config for agent-owned JSON configuration
- KV for operational variables
- memory for retrievable durable facts
- knowledge for external or curated sources
- run snapshots for immutable audit
- system state for internals only
