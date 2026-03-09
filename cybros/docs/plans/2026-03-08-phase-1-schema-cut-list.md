# Phase 1 Schema Cut List

> Historical note (2026-03-10): this schema-cut list predates the automation-conversation convergence. Its automation-specific guidance, including `run_drafts.automation_id` and automation-owned run semantics, is superseded by [`2026-03-10-automation-conversation-convergence-design.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-10-automation-conversation-convergence-design.md). Keep using this file for broader schema-cut rationale, but not as the current automation model contract.

This document defines the first schema cut for the runtime rebaseline.

It is intentionally product-first. Conduits and Nexus should adapt later.

## Principles

- prefer new first-class tables over extending generic metadata
- prefer explicit foreign keys over encoded ids inside JSON
- prefer explicit typed columns for stable identity, policy, and governance fields
- prefer `text[]` for unordered tags, capability sets, and allowed-method sets
- reserve `jsonb` for versioned snapshots, structured config blobs, patches, payload envelopes, and bounded diagnostic details
- avoid new generic `metadata` columns on runtime tables unless the payload has a clearly named bounded purpose
- prefer immutable run snapshots over mutable pointers
- v1 is single-tenant; use explicit user foreign keys only where they carry business meaning such as owner, creator, or initiating actor
- keep deployment, execution, provider, and other system runtime records as global product state unless they are directly user-owned

## Destructive Cut Rule

This schema cut assumes a destructive database reset for the programmable-agent rebaseline.

- update create-migration files in place when that is cleaner than layering compatibility migrations
- regenerate `db/schema.rb` from the new first-cut schema
- reset local and test databases instead of preserving transitional column compatibility
- do not keep generic legacy fields just to ease migration if they conflict with the target product model

## New Tables

### `run_drafts`

Purpose:

- durable planning record for one potential execution attempt before `ConversationRun` materialization

Suggested fields:

- `id`
- `conversation_id` nullable
- `automation_id` nullable
- `initiated_by_user_id` nullable
- `status`
- `permission_mode`
- `trigger_snapshot` jsonb
- `agent_program_id`
- `contract_fingerprint`
- `agent_deployment_id`
- `deployment_fingerprint`
- `deployment_activated_at`
- `provider_credential_id`
- `proposed_execution_target_id`
- `selected_model_ref`
- `runtime_governors` jsonb
- `prepare_invocation_id`
- `prepared_plan` jsonb
- `staged_public_settings_patch` jsonb
- `staged_agent_config_patch` jsonb
- `staged_kv_ops` jsonb
- `approval_state` jsonb
- `expires_at`
- `materialized_conversation_run_id` nullable
- timestamps

Suggested v1 rule:

- exactly one of `conversation_id` or `automation_id` should be present
- a draft may terminate without materializing a `ConversationRun`
- `ConversationRun` must not carry draft-only states such as `awaiting_approval`, `stale`, or `expired`
- if approval parks the draft, Cybros resumes finalization from the persisted prepared plan instead of re-running `turn.prepare`

### `agent_deployments`

Purpose:

- registered, connectable deployment binding for one `agent_program`

Suggested fields:

- `id`
- `agent_program_id`
- `transport_kind`
- `endpoint_url` nullable
- `transport_config` jsonb nullable
- `deployment_bearer_secret_ref`
- `contract_fingerprint`
- `deployment_fingerprint`
- `status`
- `health_status`
- `protocol_version`
- `agent_sdk_version`
- `supported_methods` `text[]`
- `manifest_snapshot` jsonb
- `schema_snapshot` jsonb
- `capability_snapshot` jsonb
- `inspection_details` jsonb
- `last_inspected_at`
- `last_health_checked_at`
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
- `trust_group`
- `environment`
- `tags` `text[]`
- `max_concurrent_tasks`
- `max_queued_tasks`
- `default_timeout_s`
- `cpu_limit_millicores` nullable
- `memory_limit_mb` nullable
- timestamps

Suggested v1 rule:

- `trust_group`, `environment`, and `tags` are discovery and policy inputs, not free-form metadata
- execution-capacity settings should use explicit columns instead of a generic capacity blob

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
- `capability_tags` `text[]`
- `tags` `text[]`
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
- `sandboxed`
- `max_concurrent_tasks_override` nullable
- `max_queued_tasks_override` nullable
- `default_timeout_s_override` nullable
- `cpu_limit_millicores_override` nullable
- `memory_limit_mb_override` nullable
- timestamps

Suggested v1 constraint:

- `workspace.execution_location_id` must match `execution_location_id`

Suggested v1 rule:

- discovery summaries may derive from `execution_location.trust_group`, `execution_location.environment`, `execution_location.tags`, `execution_target.sandboxed`, `workspace.capability_tags`, and `workspace.tags`
- target-switch policy should reuse the shared `allow` / `confirm` / `deny` decision semantics instead of inventing a new approval vocabulary
- execution-capacity overrides should use explicit nullable override columns instead of a generic JSON blob

### `automations`

Purpose:

- bind scheduled work to agent and execution target primitives

Suggested fields:

- `id`
- `user_id`
- `conversation_id` nullable
- `agent_program_id`
- `execution_target_id`
- `permission_mode`
- `status`
- `schedule_kind`
- `schedule_rrule`
- `schedule_timezone`
- `task_payload` jsonb
- timestamps

Suggested v1 rule:

- `Automation` is its own product aggregate; `conversation_id`, if present, is an optional dispatch or transcript binding rather than the automation's primary identity
- stable schedule fields should be explicit columns; keep `task_payload` as a versioned envelope only if task shapes are still intentionally open-ended
- if an automation run needs manual approval, represent that as durable runtime state instead of silent auto-allow

### `automation_runs`

Purpose:

- immutable execution records for automations

Suggested fields:

- `id`
- `automation_id`
- `initiated_by_user_id` nullable
- `conversation_run_id` nullable
- `status`
- `approval_state` jsonb nullable
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
- `permission_mode`
- `public_settings` jsonb
- `agent_config` jsonb
- `agent_config_schema_fingerprint`

V1 rule:

- keep the existing direct `user_id` ownership on `Conversation`
- `agent_program_id` is a first-class conversation-scoped runtime setting updated by the composer agent picker and used for future drafts and runs
- `default_execution_target_id` is a first-class conversation-scoped runtime setting updated by both the composer target picker and accepted agent target proposals
- `permission_mode` is a first-class conversation-scoped runtime preset, not metadata or public-settings state
- `public_settings` is the canonical mutable store for conversation-level public settings
- storage may be `jsonb` in v1, but the public API must remain typed and policy-gated
- `agent_config` is the canonical per-conversation agent-config store
- Cybros stores it as opaque JSON in v1
- `agent_config` should be interpreted as a namespaced store keyed by a stable selected-`AgentProgram` contract namespace, not cleared wholesale when the conversation switches agents
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
- `config_namespace`
- `global_config` jsonb
- `global_config_schema` jsonb
- `conversation_config_schema` jsonb
- `published_contract_fingerprint`
- `config_schema_fingerprint`

Purpose:

- preserve one canonical program contract even when deployments are replaced or re-inspected
- provide one stable namespace key for conversation `agent_config` storage across top-level agent switches

### `llm_provider_credentials`

Target shape:

- rename or replace the legacy `llm_providers` credential record
- keep provider catalog metadata outside this table

Add:

- `provider_key`
- `credential_type`
- `status`
- `max_concurrent_requests`
- `requests_per_minute`
- `tokens_per_minute`
- `burst_limit`
- `backoff_policy`

Purpose:

- credential-scoped limiter settings for remote LLM APIs

Suggested v1 constraint:

- one active credential per `provider_key`

### `runtime_settings`

Purpose:

- instance-scoped operator runtime settings

Suggested fields:

- `id`
- `default_worker_concurrency`
- `queue_overrides` jsonb
- `alert_thresholds` jsonb
- timestamps

Suggested v1 constraint:

- singleton or otherwise instance-scoped uniqueness

### `conversation_runs`

Add immutable snapshot fields:

- `snapshot_version`
- `initiated_by_user_id` nullable
- `effective_permission_mode`
- `agent_program_id`
- `contract_fingerprint`
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
- `permission_mode`
- `agent`
- `contract`
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
- `agent_rpc_invocation_id`
- `conversation_id`
- `scope_type`
- `scope_id`
- `deployment_fingerprint`
- `deployment_activated_at`
- `session_token_digest`
- `allowed_methods` `text[]`
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
- `deployment_activated_at`
- `request_payload_hash`
- `status`
- `result_snapshot` jsonb
- `error_snapshot` jsonb
- `last_session_id`
- timestamps

Suggested v1 constraint:

- uniqueness on `(binding_fingerprint, deployment_activated_at, scope_type, scope_id, method, invocation_id)`

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

- durable occupancy leases for execution work admitted against execution capacity

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

- use this for `provider_limit`, `execution_capacity`, and `deployment_backoff`
- parked waits do not count as admitted execution queue occupancy
- `deployment_backoff` is a scheduler retry wait for unreachable or unhealthy deployments, not a Cybros-owned self-healing mechanism

## V1 Implementation Decisions

- keep `agent_config` on `conversations` in v1; revisit a dedicated table only after programmable-agent product surfaces stabilize
- require `execution_targets` to reference active workspaces in v1; do not support soft-deleted workspace bindings
- keep `effective_policy` as one top-level immutable `jsonb` column on `conversation_runs`; do not split it into additional policy-specific columns in the first cut
- carry the domain rename to `llm_provider_credentials` through schema, model, and service code in the first cut; legacy operator-facing `/system/settings/llm_providers` route and UI names may stay until the settings surface is cleaned up
- model `provider_budget_reservations` as explicit durable rows in v1
- do not introduce new catch-all `metadata` columns on execution-domain tables in this cut; if a future payload needs storage, name it after its bounded purpose
