# Runtime Governance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add first-class runtime governance for provider-credential limits, job concurrency, and execution quotas.

**Architecture:** Keep the three governors separate. Attach LLM limits to provider credentials, keep job throughput in dedicated instance-scoped runtime settings, and attach execution quotas to execution locations with optional execution-target overrides. Use explicit columns for stable limiter and quota values, use `text[]` for tag sets, and reserve `jsonb` for bounded settings payloads. Use one shared durable coordination layer, but split admission semantics between provider-side budget reservations and execution-side capacity leases so denied work can park without monopolizing worker throughput. Treat `deployment_backoff` as a durable scheduler retry wait for deployment failures, not as a fourth governor or a self-healing supervisor loop. Collect observability data now and defer richer dashboards until later phases. The long-term LLM model should separate `ProviderSpec` from `ProviderCredential`, while v1 keeps one active credential per `provider_key` and defers credential-level load balancing and failover.

**Tech Stack:** Ruby on Rails, PostgreSQL, Solid Queue, AgentCore/DAG, Nexus

**Cross-Plan Note:** `docs/plans/2026-03-09-execution-target-discovery-design.md` defines the read-side target inventory and target-switch policy semantics that consume the explicit policy fields, tag arrays, and quota fields on `ExecutionLocation`, `Workspace`, and `ExecutionTarget` from this plan. This plan owns those schema and validation surfaces; `docs/plans/2026-03-09-agent-deployment-connection.md` owns the programmable-agent-facing inventory APIs, composer target selector, and operator target-management UI built on top of them.

**Destructive Reset Rule:** This plan assumes the programmable-agent rebaseline can reset the database. Prefer editing or replacing first-cut create migrations and regenerating `db/schema.rb` over layering compatibility migrations or preserving legacy runtime fields.

## Testing Posture

Every behavior-changing task in this plan should name exact verification files and commands.

- pure configuration or limiter logic should start with model or unit tests
- enforcement tasks should add integration coverage for the real runtime path
- the first operator-facing surface for a governance behavior should add or update a Playwright E2E flow
- browser tasks should run through `bin/ci_e2e`, not manual `bin/dev` + `bin/e2e` bootstrapping
- avoid wildcard-only acceptance or full-suite commands except for final verification

---

### Task 1: Publish The Runtime Governance Product Docs

**Files:**
- Create: `docs/product/runtime_governance.md`
- Modify: `docs/product/README.md`
- Modify: `docs/product/architecture.md`
- Modify: `docs/product/domain_model.md`
- Modify: `docs/product/execution_model.md`
- Modify: `docs/product/roadmap.md`
- Modify: `docs/product/migration_alignment.md`
- Modify: `docs/plans/2026-03-08-phase-1-schema-cut-list.md`
- Modify: `docs/plans/README.md`
- Modify: `docs/plans/2026-03-09-programmable-agent-preflight-design.md`

**Step 1: Write the normative product doc**

Document:

- the three-governor model
- credential-scoped LLM limiting
- location-first execution quotas
- operator-tunable job throughput
- deferred dashboard direction

**Step 2: Wire it into the active product docs**

Update reading order and core product references.

**Step 3: Verify coherence**

Run: `rg -n "runtime governance|ProviderCredentialLimiter|ExecutionQuota|job concurrency" docs/product docs/plans/2026-03-08-phase-1-schema-cut-list.md docs/plans/2026-03-09-programmable-agent-preflight-design.md`
Expected: the concept appears in the product docs, schema cut list, and preflight doc.

**Step 4: Commit**

```bash
git add docs/product docs/plans/README.md docs/plans/2026-03-08-phase-1-schema-cut-list.md docs/plans/2026-03-09-programmable-agent-preflight-design.md docs/plans/2026-03-08-runtime-governance-design.md docs/plans/2026-03-08-runtime-governance.md
git commit -m "docs: define runtime governance baseline"
```

### Task 2: Add The Configuration Schema And Models

**Files:**
- Modify or replace: `db/migrate/20260226000004_create_llm_providers.rb`
- Create: `db/migrate/*_create_runtime_settings.rb`
- Modify or create: `app/models/llm_provider_credential.rb`
- Create: `app/models/runtime_setting.rb`
- Modify: `db/schema.rb`
- Test: `test/models/llm_provider_credential_test.rb`
- Test: `test/models/runtime_setting_test.rb`

**Step 1: Write the failing tests**

Cover:

- provider credential accepts explicit credential-scoped limiter fields
- only one active credential exists per `provider_key`
- invalid limiter field combinations are rejected
- instance-scoped runtime settings store job-throughput settings in a stable shape

**Step 2: Run the targeted tests**

Run: `bin/rails test test/models/llm_provider_credential_test.rb test/models/runtime_setting_test.rb`
Expected: failures due to missing limiter fields, runtime-setting fields, or validation helpers.

**Step 3: Add the minimal schema and validation layer**

Keep limiter and job-throughput fields explicit. Use bounded JSON only where the shape is intentionally open, such as `queue_overrides` or `alert_thresholds`. Do not hide stable governance values in ad hoc metadata.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/models/llm_provider_credential_test.rb test/models/runtime_setting_test.rb`
Expected: PASS.

**Step 5: Commit**

```bash
git add db/migrate app/models db/schema.rb test/models
git commit -m "feat: add runtime governance config fields"
```

### Task 3: Add Execution Quota Fields To Execution Models

**Files:**
- Modify: `db/migrate/*_create_execution_locations.rb`
- Modify: `db/migrate/*_create_workspaces.rb`
- Modify: `db/migrate/*_create_execution_targets.rb`
- Modify: `app/models/execution_location.rb`
- Modify: `app/models/workspace.rb`
- Modify: `app/models/execution_target.rb`
- Modify: `db/schema.rb`
- Test: `test/models/execution_location_test.rb`
- Test: `test/models/workspace_test.rb`
- Test: `test/models/execution_target_test.rb`

**Step 1: Write the failing tests**

Cover:

- location-level execution-quota fields
- workspace capability and discovery fields
- target-level quota override fields
- override validation shape
- location, workspace, and target policy fields and tag arrays needed by execution-target visibility and switch-policy resolution
- location/workspace ownership constraints needed by execution-target management surfaces

**Step 2: Run the targeted tests**

Run: `bin/rails test test/models/execution_location_test.rb test/models/workspace_test.rb test/models/execution_target_test.rb`
Expected: failures due to missing quota fields, policy fields, tag arrays, or validation rules.

**Step 3: Add the quota fields and validation helpers**

Use `ExecutionLocation` as the primary quota-policy holder and `ExecutionTarget` only as an override surface for quota plus discovery-policy fields. Stable policy inputs such as `trust_group`, `environment`, `sandboxed`, and tag arrays should remain explicit columns or `text[]` sets. Do not merge execution quotas and target-switch policy into one setting blob.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/models/execution_location_test.rb test/models/workspace_test.rb test/models/execution_target_test.rb`
Expected: PASS.

**Step 5: Commit**

```bash
git add db/migrate app/models/execution_location.rb app/models/workspace.rb app/models/execution_target.rb db/schema.rb test/models
git commit -m "feat: add execution quota and target policy fields"
```

### Task 4: Resolve Runtime Governors During Run Planning

**Files:**
- Create: `app/services/runtime_governance/admission_coordinator.rb`
- Create: `app/services/runtime_governance/provider_credential_limiter.rb`
- Create: `app/services/runtime_governance/provider_budget_reservations.rb`
- Create: `app/services/runtime_governance/job_concurrency_settings.rb`
- Create: `app/services/runtime_governance/execution_quota_resolver.rb`
- Create: `app/services/runtime_governance/execution_capacity_leases.rb`
- Create: `app/services/runtime_governance/runtime_waits.rb`
- Modify: `lib/cybros/agent_runtime_resolver.rb`
- Create or modify: `app/models/run_draft.rb`
- Modify: `app/models/conversation_run.rb`
- Test: `test/models/run_draft_test.rb`
- Test: `test/services/runtime_governance/admission_coordinator_test.rb`
- Test: `test/services/runtime_governance/provider_credential_limiter_test.rb`
- Test: `test/services/runtime_governance/execution_quota_resolver_test.rb`
- Test: `test/services/runtime_governance/provider_budget_reservations_test.rb`
- Test: `test/services/runtime_governance/execution_capacity_leases_test.rb`
- Test: `test/services/runtime_governance/runtime_waits_test.rb`
- Test: `test/lib/cybros/agent_runtime_resolver_test.rb`

**Step 1: Write the failing tests**

Cover:

- shared coordination across provider reservations and execution leases
- provider reservation and settlement semantics
- execution lease acquire, heartbeat, and recovery semantics
- durable denial metadata and parked retry semantics
- `deployment_backoff` semantics for unreachable or unhealthy deployments without worker monopolization
- provider limiter resolution by credential
- execution quota resolution by location with target override
- resolved runtime governor facts being available during run planning

**Step 2: Run the targeted tests**

Run: `bin/rails test test/models/run_draft_test.rb test/services/runtime_governance/admission_coordinator_test.rb test/services/runtime_governance/provider_credential_limiter_test.rb test/services/runtime_governance/execution_quota_resolver_test.rb test/services/runtime_governance/provider_budget_reservations_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/services/runtime_governance/runtime_waits_test.rb test/lib/cybros/agent_runtime_resolver_test.rb`
Expected: failures due to missing resolver code.

**Step 3: Implement the minimal runtime-governance services**

Do not enforce everything inside the resolver. Resolve facts cleanly first, persist resolved governor facts on the open `RunDraft`, and make limiter and quota enforcement depend on one shared durable coordination layer with distinct provider-budget and execution-lease primitives.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/models/run_draft_test.rb test/services/runtime_governance/admission_coordinator_test.rb test/services/runtime_governance/provider_credential_limiter_test.rb test/services/runtime_governance/execution_quota_resolver_test.rb test/services/runtime_governance/provider_budget_reservations_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/services/runtime_governance/runtime_waits_test.rb test/lib/cybros/agent_runtime_resolver_test.rb`
Expected: PASS.

**Step 5: Commit**

```bash
git add app/services/runtime_governance lib/cybros/agent_runtime_resolver.rb app/models/run_draft.rb app/models/conversation_run.rb test/models/run_draft_test.rb test/services/runtime_governance test/lib/cybros
git commit -m "feat: resolve runtime governance during run planning"
```

### Task 5: Enforce Provider Limits Around LLM Calls

**Files:**
- Modify: `lib/agent_core/resources/provider/*`
- Modify: `lib/agent_core/observability/*`
- Test: `test/lib/agent_core/resources/provider/rate_limit_enforcement_test.rb`
- Test: `test/integration/provider_credential_limiter_flow_test.rb`
- Test: `test/e2e/conversation_provider_limit_backoff.spec.ts`

**Step 1: Write the failing tests**

Cover:

- permit acquisition before provider requests
- provider request identifier propagation for recovery
- reservation settlement after request completion
- limiter denial or backoff behavior
- denied work parking without monopolizing worker throughput
- recovery behavior after lost reply or abandoned reservation
- limiter-hit observability facts
- real conversation-run flow blocked or delayed by provider-credential limits

**Step 2: Run the targeted tests**

Run: `bin/rails test test/lib/agent_core/resources/provider/rate_limit_enforcement_test.rb test/integration/provider_credential_limiter_flow_test.rb`
Expected: failures due to missing limiter hooks.

Run: `bin/ci_e2e test/e2e/conversation_provider_limit_backoff.spec.ts`
Expected: FAIL because limiter pressure is not yet surfaced through the real flow.

**Step 3: Implement minimal provider-limit enforcement**

Keep the provider limiter credential-scoped and independent from worker concurrency. Denied work must park durably instead of spinning inside a worker, and reservation recovery must reconcile rather than blindly replay external requests.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/lib/agent_core/resources/provider/rate_limit_enforcement_test.rb test/integration/provider_credential_limiter_flow_test.rb`
Expected: PASS.

Run: `bin/ci_e2e test/e2e/conversation_provider_limit_backoff.spec.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add lib/agent_core test/lib/agent_core/resources/provider/rate_limit_enforcement_test.rb test/integration/provider_credential_limiter_flow_test.rb test/e2e/conversation_provider_limit_backoff.spec.ts
git commit -m "feat: enforce provider credential limits"
```

### Task 6: Enforce Execution Quotas Around Nexus-Bound Work

**Files:**
- Modify: `app/services` or directive-planning services that prepare Nexus work
- Modify: `app/models/conversation_run.rb`
- Test: `test/services/runtime_governance/execution_quota_enforcer_test.rb`
- Test: `test/integration/execution_quota_enforcement_test.rb`
- Test: `test/e2e/conversation_execution_quota_denial.spec.ts`

**Step 1: Write the failing tests**

Cover:

- location quota enforced by default
- target override applied when present
- quota denial surfaced as durable run facts
- execution request identifier propagation for reconciliation
- lease expiry or heartbeat recovery
- quota-denied work parking and later retry without holding the worker slot
- real execution-planning flow records the denial without bypassing the quota boundary

**Step 2: Run the targeted tests**

Run: `bin/rails test test/services/runtime_governance/execution_quota_enforcer_test.rb test/integration/execution_quota_enforcement_test.rb`
Expected: failures around missing quota enforcement.

Run: `bin/ci_e2e test/e2e/conversation_execution_quota_denial.spec.ts`
Expected: FAIL because quota denials are not yet surfaced through the real conversation flow.

**Step 3: Implement minimal execution-quota enforcement**

Protect Nexus-managed work only. Do not rate-limit `AgentProgram` RPC. Quota-denied work must park durably instead of spinning in-process, and execution recovery must reconcile abandoned leases before replaying work.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/services/runtime_governance/execution_quota_enforcer_test.rb test/integration/execution_quota_enforcement_test.rb`
Expected: PASS.

Run: `bin/ci_e2e test/e2e/conversation_execution_quota_denial.spec.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add app test/services/runtime_governance/execution_quota_enforcer_test.rb test/integration/execution_quota_enforcement_test.rb test/e2e/conversation_execution_quota_denial.spec.ts
git commit -m "feat: enforce execution quotas"
```

### Task 7: Add System Settings Surfaces For Operators

**Files:**
- Modify: `app/controllers/system/settings/llm_providers_controller.rb`
- Create or modify system-settings controllers/views for runtime/job settings
- Create or modify system-settings controllers/views for execution locations and workspaces
- Test: `test/integration/system_settings_runtime_governance_test.rb`
- Test: `test/e2e/runtime_governance_settings.spec.ts`

**Step 1: Write the failing tests**

Cover:

- editing provider limiter fields
- editing runtime job settings
- editing execution-location quota fields
- managing workspace records used by execution-target selection
- real browser flow for saving runtime-governance settings through system settings

**Step 2: Run the targeted tests**

Run: `bin/rails test test/integration/system_settings_runtime_governance_test.rb`
Expected: failures due to missing settings surfaces.

Run: `bin/ci_e2e test/e2e/runtime_governance_settings.spec.ts`
Expected: FAIL because the settings flow is not yet wired.

**Step 3: Implement the operator settings UI**

Keep this as system settings, not end-user product UI. `ExecutionTarget` settings remain owned by `docs/plans/2026-03-09-agent-deployment-connection.md` Task 4 because that surface is coupled to conversation target selection and target-switch semantics, but this task must expose the execution-location and workspace records that Task 4 depends on.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/integration/system_settings_runtime_governance_test.rb`
Expected: PASS.

Run: `bin/ci_e2e test/e2e/runtime_governance_settings.spec.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add app/controllers app/views test/integration/system_settings_runtime_governance_test.rb test/e2e/runtime_governance_settings.spec.ts
git commit -m "feat: add runtime governance system settings"
```

### Task 8: Add Baseline Observability For Later Dashboards

**Files:**
- Modify: `lib/agent_core/observability/*`
- Modify: run or event projection code where needed
- Test: `test/lib/agent_core/observability/runtime_governance_events_test.rb`
- Test: `test/integration/runtime_governance_observability_test.rb`
- Test: `test/e2e/runtime_governance_observability.spec.ts`

**Step 1: Write the failing tests**

Cover:

- provider limiter hit events
- execution quota denial events
- per-location queue depth or saturation facts where available
- lease recovery events
- provider reservation reconciliation events
- deployment backoff wait events
- operator-visible observability for a real quota or limiter event through the browser

**Step 2: Run the targeted tests**

Run: `bin/rails test test/lib/agent_core/observability/runtime_governance_events_test.rb test/integration/runtime_governance_observability_test.rb`
Expected: failures in the targeted observability areas.

Run: `bin/ci_e2e test/e2e/runtime_governance_observability.spec.ts`
Expected: FAIL because the observability flow is not yet surfaced.

**Step 3: Implement minimal facts, not final dashboards**

Collect enough data for:

- agent-work views
- host-work views
- timeout and recovery diagnosis

Do not build the full dashboard yet.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/lib/agent_core/observability/runtime_governance_events_test.rb test/integration/runtime_governance_observability_test.rb`
Expected: PASS.

Run: `bin/ci_e2e test/e2e/runtime_governance_observability.spec.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add lib/agent_core app test/lib/agent_core/observability/runtime_governance_events_test.rb test/integration/runtime_governance_observability_test.rb test/e2e/runtime_governance_observability.spec.ts
git commit -m "feat: add runtime governance observability"
```

## Cross-Plan Execution Sequence

For a straight-through implementation run, execute this plan in the following relationship to `2026-03-09-agent-deployment-connection.md`:

1. Land Task 1 and Task 2 here before code starts depending on explicit provider-credential limiter fields or runtime settings.
2. Land Task 3 and Task 4 here before `2026-03-09-agent-deployment-connection.md` Task 4 and Task 5, because target discovery and draft re-resolution consume these schema surfaces and resolved governor facts.
3. Land Task 5 through Task 8 after the programmable-agent draft and RPC path exists, because those tasks enforce and observe real runtime behavior.

## Acceptance

- the runtime-governance schema is expressed through explicit limiter fields, explicit execution-quota fields, and `text[]` tag sets instead of vague `jsonb` labels or config blobs
- the destructive reset path is explicit: first-cut migrations may be edited or replaced in place and `db/schema.rb` is regenerated from the new baseline
- target discovery and target-switch policy inputs are owned by `ExecutionLocation`, `Workspace`, and `ExecutionTarget` through explicit policy fields and tag arrays
- provider-budget reservations and execution-capacity leases remain separate admission primitives even though they share one durable coordination layer
- blocked work parks durably for `provider_limit`, `execution_quota`, and `deployment_backoff` without monopolizing worker throughput
- operator-facing settings and observability tasks have concrete integration or E2E verification commands before the plan is considered complete
