# Phase 1 Schema Cut List

This document defines the first schema cut for the runtime rebaseline.

It is intentionally product-first. Conduits and Nexus should adapt later.

## Principles

- prefer new first-class tables over extending generic metadata
- prefer explicit foreign keys over encoded ids inside JSON
- prefer immutable run snapshots over mutable pointers

## New Tables

### `run_drafts`

Purpose:

- durable planning record for one potential execution attempt before `ConversationRun` materialization

Suggested fields:

- `id`
- `conversation_id`
- `status`
- `trigger_snapshot` jsonb
- `agent_program_id`
- `agent_deployment_id`
- `deployment_fingerprint`
- `deployment_activated_at`
- `provider_credential_id`
- `proposed_execution_target_id`
- `selected_model_ref`
- `runtime_governors` jsonb
- `staged_public_settings_patch` jsonb
- `staged_agent_config_patch` jsonb
- `staged_kv_ops` jsonb
- `approval_state` jsonb
- `expires_at`
- `materialized_conversation_run_id` nullable
- timestamps

Suggested v1 rule:

- a draft may terminate without materializing a `ConversationRun`
- `ConversationRun` must not carry draft-only states such as `awaiting_approval`, `stale`, or `expired`

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
- `public_settings` jsonb
- `agent_config` jsonb
- `agent_config_schema_fingerprint`

V1 rule:

- `public_settings` is the canonical mutable store for conversation-level public settings
- storage may be `jsonb` in v1, but the public API must remain typed and policy-gated
- `agent_config` is the canonical per-conversation agent-config store
- Cybros stores it as opaque JSON in v1
- mutate it through explicit public APIs, not metadata patches

Remove from product ownership over time:

- conversation-critical ownership hidden in `metadata["agent"]`

Keep only for transitional or internal use:

- non-canonical internal metadata

## Existing Table Extensions

### `agent_programs`

Target shape:

- keep `AgentProgram` as the canonical owner of manifest and config-contract semantics

Add:

- `manifest_snapshot` jsonb
- `global_config_schema` jsonb
- `conversation_config_schema` jsonb
- `config_schema_fingerprint`

Purpose:

- preserve one canonical program contract even when deployments are replaced or re-inspected

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
- `deployment_activated_at`
- `provider_credential_id`
- `execution_target_id`
- `selected_model_ref`
- `effective_public_settings` jsonb
- `effective_agent_config` jsonb
- `agent_config_schema_fingerprint`
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
- `public_settings`
- `agent_config`
- `policy`
- `governors`

Suggested v1 rule:

- materialize `ConversationRun` only after draft finalization
- finalize the snapshot shape when the run is queued
- keep the shape versioned and immutable across approval, resume, retry, and completion
- pin the deployment binding using both fingerprint and activation epoch

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

Suggested v1 rule:

- this table stores current KV state only
- append-only KV history is deferred

## Internal Runtime State Tables

These are durable system-state tables, not product-facing selectors.

### `agent_rpc_sessions`

Purpose:

- bounded authorization state for one lifecycle request or one turn-hook invocation attempt

Suggested fields:

- `id`
- `agent_deployment_id`
- `agent_program_id`
- `conversation_id`
- `scope_type`
- `scope_id`
- `deployment_fingerprint`
- `deployment_activated_at`
- `allowed_methods` jsonb
- `expires_at`
- `status`
- timestamps

### `agent_rpc_invocations`

Purpose:

- durable logical record for one RPC lifecycle or turn-hook call

Suggested fields:

- `id`
- `agent_deployment_id`
- `conversation_id`
- `scope_type`
- `scope_id`
- `method`
- `invocation_id`
- `binding_fingerprint`
- `request_payload_hash`
- `status`
- `result_snapshot` jsonb
- `error_snapshot` jsonb
- `last_session_id`
- timestamps

Suggested v1 constraint:

- uniqueness on `(binding_fingerprint, scope_type, scope_id, method, invocation_id)`

### `agent_rpc_operation_receipts`

Purpose:

- de-duplicate agent-to-Cybros callback side effects across replayed sessions

Suggested fields:

- `id`
- `agent_rpc_invocation_id`
- `operation_id`
- `method`
- `payload_hash`
- `status`
- `response_snapshot` jsonb
- timestamps

Suggested v1 constraint:

- uniqueness on `(agent_rpc_invocation_id, operation_id)`

### `provider_budget_reservations`

Purpose:

- durable reservation and settlement state for provider-side request and token budgets

Suggested fields:

- `id`
- `provider_credential_id`
- `provider_request_id`
- `request_units`
- `estimated_tokens`
- `actual_tokens`
- `reserved_until`
- `status`
- `reconciliation_metadata` jsonb
- timestamps

Suggested v1 constraint:

- uniqueness on `(provider_credential_id, provider_request_id)`

### `execution_capacity_leases`

Purpose:

- durable occupancy leases for execution work admitted against an execution quota

Suggested fields:

- `id`
- `subject_type`
- `subject_id`
- `execution_request_id`
- `holder_type`
- `holder_id`
- `slots`
- `lease_expires_at`
- `heartbeat_at`
- `status`
- `recovery_metadata` jsonb
- timestamps

Suggested v1 constraint:

- uniqueness on `(subject_type, subject_id, execution_request_id)`

### `runtime_waits`

Purpose:

- durable parked-work state for blocked runtime progress

Suggested fields:

- `id`
- `owner_type`
- `owner_id`
- `reason_type`
- `subject_type`
- `subject_id`
- `retry_at`
- `ordering_key`
- `details` jsonb
- `status`
- timestamps

Suggested v1 rule:

- use this for `provider_limit`, `execution_quota`, and `deployment_backoff`
- parked waits do not count as admitted execution queue occupancy

## Open Questions To Resolve During Implementation

- whether `agent_config` should stay on `conversations` or move to a dedicated table later
- whether `execution_targets` should allow soft-deleted workspaces
- how much of `effective_policy` belongs in top-level columns vs `snapshot`
- how far to carry the rename from legacy `llm_providers` to `llm_provider_credentials` in the first cut
- how much of `provider_budget_reservations` should be explicit rows versus a specialized limiter backend with equivalent durability guarantees
