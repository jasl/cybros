# Phase 1 Schema Cut List

This document defines the first schema cut for the runtime rebaseline.

It is intentionally product-first. Conduits and Nexus should adapt later.

## Principles

- prefer new first-class tables over extending generic metadata
- prefer explicit foreign keys over encoded ids inside JSON
- prefer immutable run snapshots over mutable pointers

## New Tables

### `agent_deployments`

Purpose:

- registered, connectable deployment binding for one `agent_program`

Suggested fields:

- `id`
- `agent_program_id`
- `transport_kind`
- `endpoint` or transport config jsonb
- auth or secret reference
- `revision` or deployment fingerprint
- `status`
- `health_status`
- `manifest_snapshot` jsonb
- `schema_snapshot` jsonb
- `capability_snapshot` jsonb
- `runtime_metadata` jsonb
- `activated_at`
- `deactivated_at`
- timestamps

Suggested v1 constraint:

- one active deployment per agent program

### `execution_locations`

Purpose:

- product-level execution location records

Suggested fields:

- `id`
- `name`
- `kind`
- `platform`
- `status`
- `quota_config` jsonb
- `labels` jsonb
- `metadata` jsonb
- timestamps

### `workspaces`

Purpose:

- location-scoped working directories or handles

Suggested fields:

- `id`
- `execution_location_id`
- `name`
- `root_path`
- `workspace_type`
- `status`
- `capabilities` jsonb
- `metadata` jsonb
- timestamps

Suggested v1 constraint:

- uniqueness on `(execution_location_id, root_path)` if `root_path` is used

### `execution_targets`

Purpose:

- reusable runtime handles for `location + workspace`

Suggested fields:

- `id`
- `execution_location_id`
- `workspace_id`
- `name`
- `status`
- `quota_override` jsonb
- `metadata` jsonb
- timestamps

Suggested v1 constraint:

- `workspace.execution_location_id` must match `execution_location_id`

### `automations`

Purpose:

- bind scheduled work to agent and execution target primitives

Suggested fields:

- `id`
- `user_id`
- `conversation_id` nullable
- `agent_program_id`
- `execution_target_id`
- `status`
- `schedule_kind`
- `schedule_payload` jsonb
- `task_payload` jsonb
- timestamps

### `automation_runs`

Purpose:

- immutable execution records for automations

Suggested fields:

- `id`
- `automation_id`
- `conversation_run_id` nullable
- `status`
- `scheduled_for`
- `started_at`
- `finished_at`
- `snapshot` jsonb
- timestamps

## Conversation Changes

### `conversations`

Add:

- `agent_program_id`
- `default_execution_target_id`
- `agent_config` jsonb

V1 rule:

- `agent_config` is the canonical per-conversation agent-config store
- Cybros stores it as opaque JSON in v1
- mutate it through explicit public APIs, not metadata patches

Remove from product ownership over time:

- conversation-critical ownership hidden in `metadata["agent"]`

Keep only for transitional or internal use:

- non-canonical internal metadata

## Existing Table Extensions

### `llm_provider_credentials`

Target shape:

- rename or replace the legacy `llm_providers` credential record
- keep provider catalog metadata outside this table

Add:

- `provider_key`
- `credential_type`
- `status`
- `rate_limit_config` jsonb

Purpose:

- credential-scoped limiter settings for remote LLM APIs

Suggested v1 constraint:

- one active credential per `provider_key`

### `runtime_settings`

Purpose:

- deployment-scoped operator runtime settings

Suggested fields:

- `id`
- `job_config` jsonb
- `metadata` jsonb
- timestamps

Suggested v1 constraint:

- singleton or otherwise deployment-scoped uniqueness

### `conversation_runs`

Add immutable snapshot fields:

- `snapshot_version`
- `agent_program_id`
- `agent_deployment_id`
- `deployment_fingerprint`
- `provider_credential_id`
- `execution_target_id`
- `selected_model_ref`
- `effective_agent_config` jsonb
- `effective_policy` jsonb
- `runtime_governors` jsonb
- `snapshot` jsonb

Recommended v1 snapshot sections:

- `trigger`
- `agent`
- `deployment`
- `provider_credential`
- `model`
- `execution_target`
- `policy`
- `governors`

Suggested v1 rule:

- materialize `ConversationRun` only after draft finalization
- finalize the snapshot shape when the run is queued
- keep the shape versioned and immutable across approval, resume, retry, and completion

## Conversation State Tables

### `conversation_kv_entries`

Purpose:

- shared operational KV

Suggested fields:

- `id`
- `conversation_id`
- `key`
- `value` jsonb
- `written_by_type`
- `written_by_id`
- timestamps

Suggested v1 constraint:

- uniqueness on `(conversation_id, key)`

## Open Questions To Resolve During Implementation

- whether `agent_config` should stay on `conversations` or move to a dedicated table later
- whether `execution_targets` should allow soft-deleted workspaces
- how much of `effective_policy` belongs in top-level columns vs `snapshot`
- how far to carry the rename from legacy `llm_providers` to `llm_provider_credentials` in the first cut
- how much execution quota should be enforced in Cybros planning versus only in Nexus execution
