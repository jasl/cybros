# Runtime Governance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add first-class runtime governance for provider-credential limits, job concurrency, and execution quotas.

**Architecture:** Keep the three governors separate. Attach LLM limits to provider credentials, keep job throughput in dedicated deployment-scoped runtime settings, and attach execution quotas to execution locations with optional execution-target overrides. Collect observability data now and defer richer dashboards until later phases. The long-term LLM model should separate `ProviderSpec` from `ProviderCredential`, while v1 keeps one active credential per `provider_key` and defers credential-level load balancing and failover.

**Tech Stack:** Ruby on Rails, PostgreSQL, Solid Queue, AgentCore/DAG, Nexus

## Testing Posture

Every behavior-changing task in this plan should name exact verification files and commands.

- pure configuration or limiter logic should start with model or unit tests
- enforcement tasks should add integration coverage for the real runtime path
- the first operator-facing surface for a governance behavior should add or update a Playwright E2E flow
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
- Modify: `docs/plans/2026-03-08-runtime-rebaseline.md`

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

Run: `rg -n "runtime governance|ProviderCredentialLimiter|ExecutionQuota|job concurrency" docs/product docs/plans/2026-03-08-phase-1-schema-cut-list.md docs/plans/2026-03-08-runtime-rebaseline.md`
Expected: the concept appears in the product docs, schema cut list, and rebaseline plan.

**Step 4: Commit**

```bash
git add docs/product docs/plans/2026-03-08-phase-1-schema-cut-list.md docs/plans/2026-03-08-runtime-rebaseline.md docs/plans/2026-03-08-runtime-governance-design.md docs/plans/2026-03-08-runtime-governance.md
git commit -m "docs: define runtime governance baseline"
```

### Task 2: Add The Configuration Schema And Models

**Files:**
- Create or modify: `db/migrate/*_rename_llm_providers_to_llm_provider_credentials.rb`
- Create or modify: `db/migrate/*_add_rate_limit_config_to_llm_provider_credentials.rb`
- Create: `db/migrate/*_create_runtime_settings.rb`
- Modify: `app/models/llm_provider_credential.rb` or transitional legacy wrapper
- Create: `app/models/runtime_setting.rb`
- Modify: `db/schema.rb`
- Test: `test/models/llm_provider_credential_test.rb`
- Test: `test/models/runtime_setting_test.rb`

**Step 1: Write the failing tests**

Cover:

- provider credential accepts credential-scoped limiter config
- only one active credential exists per `provider_key`
- invalid limiter config is rejected
- deployment-scoped runtime settings store job-concurrency settings in a stable shape

**Step 2: Run the targeted tests**

Run: `bin/rails test test/models/llm_provider_credential_test.rb test/models/runtime_setting_test.rb`
Expected: failures due to missing config fields or validation helpers.

**Step 3: Add the minimal schema and validation layer**

Keep the limiter config and runtime job settings explicit. Do not hide them in ad hoc metadata.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/models/llm_provider_credential_test.rb test/models/runtime_setting_test.rb`
Expected: PASS.

**Step 5: Commit**

```bash
git add db/migrate app/models db/schema.rb test/models
git commit -m "feat: add runtime governance config models"
```

### Task 3: Add Execution Quota Fields To Execution Models

**Files:**
- Modify: `db/migrate/*_create_execution_locations.rb`
- Modify: `db/migrate/*_create_execution_targets.rb`
- Modify: `app/models/execution_location.rb`
- Modify: `app/models/execution_target.rb`
- Modify: `db/schema.rb`
- Test: `test/models/execution_location_test.rb`
- Test: `test/models/execution_target_test.rb`

**Step 1: Write the failing tests**

Cover:

- location-level execution quota config
- target-level quota override config
- override validation shape

**Step 2: Run the targeted tests**

Run: `bin/rails test test/models/execution_location_test.rb test/models/execution_target_test.rb`
Expected: failures due to missing quota fields or validation rules.

**Step 3: Add the quota fields and validation helpers**

Use `ExecutionLocation` as the primary policy holder and `ExecutionTarget` only as an override surface.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/models/execution_location_test.rb test/models/execution_target_test.rb`
Expected: PASS.

**Step 5: Commit**

```bash
git add db/migrate app/models/execution_location.rb app/models/execution_target.rb db/schema.rb test/models
git commit -m "feat: add execution quota config"
```

### Task 4: Resolve Runtime Governors During Run Planning

**Files:**
- Create: `app/services/runtime_governance/provider_credential_limiter.rb`
- Create: `app/services/runtime_governance/job_concurrency_settings.rb`
- Create: `app/services/runtime_governance/execution_quota_resolver.rb`
- Modify: `lib/cybros/agent_runtime_resolver.rb`
- Modify: `app/models/conversation_run.rb`
- Test: `test/services/runtime_governance/provider_credential_limiter_test.rb`
- Test: `test/services/runtime_governance/execution_quota_resolver_test.rb`
- Test: `test/lib/cybros/agent_runtime_resolver_test.rb`

**Step 1: Write the failing tests**

Cover:

- provider limiter resolution by credential
- execution quota resolution by location with target override
- resolved runtime governor facts being available during run planning

**Step 2: Run the targeted tests**

Run: `bin/rails test test/services/runtime_governance/provider_credential_limiter_test.rb test/services/runtime_governance/execution_quota_resolver_test.rb test/lib/cybros/agent_runtime_resolver_test.rb`
Expected: failures due to missing resolver code.

**Step 3: Implement the minimal runtime-governance services**

Do not enforce everything inside the resolver. Resolve facts cleanly first.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/services/runtime_governance/provider_credential_limiter_test.rb test/services/runtime_governance/execution_quota_resolver_test.rb test/lib/cybros/agent_runtime_resolver_test.rb`
Expected: PASS.

**Step 5: Commit**

```bash
git add app/services/runtime_governance lib/cybros/agent_runtime_resolver.rb app/models/conversation_run.rb test/services/runtime_governance test/lib/cybros
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
- limiter denial or backoff behavior
- limiter-hit observability facts
- real conversation-run flow blocked or delayed by provider-credential limits

**Step 2: Run the targeted tests**

Run: `bin/rails test test/lib/agent_core/resources/provider/rate_limit_enforcement_test.rb test/integration/provider_credential_limiter_flow_test.rb`
Expected: failures due to missing limiter hooks.

Run: `bin/e2e test/e2e/conversation_provider_limit_backoff.spec.ts`
Expected: FAIL once the dev server is running because limiter pressure is not yet surfaced through the real flow.

**Step 3: Implement minimal provider-limit enforcement**

Keep the provider limiter credential-scoped and independent from worker concurrency.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/lib/agent_core/resources/provider/rate_limit_enforcement_test.rb test/integration/provider_credential_limiter_flow_test.rb`
Expected: PASS.

Run: `bin/e2e test/e2e/conversation_provider_limit_backoff.spec.ts`
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
- real execution-planning flow records the denial without bypassing the quota boundary

**Step 2: Run the targeted tests**

Run: `bin/rails test test/services/runtime_governance/execution_quota_enforcer_test.rb test/integration/execution_quota_enforcement_test.rb`
Expected: failures around missing quota enforcement.

Run: `bin/e2e test/e2e/conversation_execution_quota_denial.spec.ts`
Expected: FAIL once the dev server is running because quota denials are not yet surfaced through the real conversation flow.

**Step 3: Implement minimal execution-quota enforcement**

Protect Nexus-managed work only. Do not rate-limit `AgentProgram` RPC.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/services/runtime_governance/execution_quota_enforcer_test.rb test/integration/execution_quota_enforcement_test.rb`
Expected: PASS.

Run: `bin/e2e test/e2e/conversation_execution_quota_denial.spec.ts`
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
- Create or modify system-settings controllers/views for execution locations and targets
- Test: `test/integration/system_settings_runtime_governance_test.rb`
- Test: `test/e2e/runtime_governance_settings.spec.ts`

**Step 1: Write the failing tests**

Cover:

- editing provider limiter config
- editing runtime job settings
- editing execution quota config
- real browser flow for saving runtime-governance settings through system settings

**Step 2: Run the targeted tests**

Run: `bin/rails test test/integration/system_settings_runtime_governance_test.rb`
Expected: failures due to missing settings surfaces.

Run: `bin/e2e test/e2e/runtime_governance_settings.spec.ts`
Expected: FAIL once the dev server is running because the settings flow is not yet wired.

**Step 3: Implement the operator settings UI**

Keep this as system settings, not end-user product UI.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/integration/system_settings_runtime_governance_test.rb`
Expected: PASS.

Run: `bin/e2e test/e2e/runtime_governance_settings.spec.ts`
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
- operator-visible observability for a real quota or limiter event through the browser

**Step 2: Run the targeted tests**

Run: `bin/rails test test/lib/agent_core/observability/runtime_governance_events_test.rb test/integration/runtime_governance_observability_test.rb`
Expected: failures in the targeted observability areas.

Run: `bin/e2e test/e2e/runtime_governance_observability.spec.ts`
Expected: FAIL once the dev server is running because the observability flow is not yet surfaced.

**Step 3: Implement minimal facts, not final dashboards**

Collect enough data for:

- agent-work views
- host-work views

Do not build the full dashboard yet.

**Step 4: Re-run the targeted tests**

Run: `bin/rails test test/lib/agent_core/observability/runtime_governance_events_test.rb test/integration/runtime_governance_observability_test.rb`
Expected: PASS.

Run: `bin/e2e test/e2e/runtime_governance_observability.spec.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add lib/agent_core app test/lib/agent_core/observability/runtime_governance_events_test.rb test/integration/runtime_governance_observability_test.rb test/e2e/runtime_governance_observability.spec.ts
git commit -m "feat: add runtime governance observability"
```
