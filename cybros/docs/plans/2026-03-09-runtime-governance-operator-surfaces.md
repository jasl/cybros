# Runtime Governance Operator Surfaces Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
>
> **Status:** completed on 2026-03-10 on branch `codex/programmable-agent-rebaseline`.
>
> **Acceptance note:** use this document as the closed implementation record for the operator-surface slice of `PA-006`. The final verification sweep below passed after the docs-alignment task landed.

**Status:** completed on 2026-03-10 on `codex/programmable-agent-rebaseline`.

**Delivered scope:** provider limiter editing, runtime settings, execution locations, workspaces, execution-target overrides, and a read-only runtime-governance observability surface backed by durable waits, reservations, leases, and run snapshots.

**Final acceptance evidence:** `PARALLEL_WORKERS=1 bin/rails test test/integration/system_settings_llm_provider_governance_test.rb test/system/system_settings_llm_provider_governance_test.rb test/integration/system_settings_runtime_settings_test.rb test/system/system_settings_runtime_settings_test.rb test/integration/system_settings_execution_locations_test.rb test/system/system_settings_execution_locations_test.rb test/integration/system_settings_workspaces_test.rb test/system/system_settings_workspaces_test.rb test/integration/system_settings_execution_targets_test.rb test/system/system_settings_execution_targets_test.rb test/integration/system_settings_runtime_governance_test.rb test/system/system_settings_runtime_governance_test.rb test/integration/runtime_governance_observability_test.rb test/integration/execution_target_inventory_test.rb test/integration/llm_providers_test.rb test/integration/system_settings_automations_test.rb test/system/system_settings_automations_test.rb test/services/runtime_governance/provider_budget_reservations_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/services/runtime_governance/runtime_waits_test.rb test/integration/execution_capacity_enforcement_test.rb`

**Goal:** complete the operator-facing runtime governance slice by adding provider limiter editing, runtime settings, execution topology management, and minimal observability that matches the shipped `execution_capacity` and scheduled-automation runtime.

**Architecture:** reuse the durable runtime-governance primitives that already landed. Operator surfaces should edit first-class columns on existing models and read current runtime facts from reservations, leases, waits, and run snapshots instead of inventing a separate dashboard/event pipeline first. Keep each page independently shippable and independently verifiable.

**Tech Stack:** Ruby on Rails 8.2 alpha, Hotwire, Tailwind/DaisyUI, Minitest, browser-backed system tests

---

## Cross-Plan Dependencies

- This plan supersedes Task 6 in `docs/plans/2026-03-08-runtime-governance.md`.
- `docs/plans/2026-03-09-execution-capacity-and-scheduled-automation.md` already closed `PA-011` and `PA-012`; this plan assumes those runtime paths are the current truth.
- `docs/plans/2026-03-09-agent-deployment-connection.md` and automation/operator plans already expose adjacent settings pages; follow their controller/view/test conventions instead of inventing a new settings pattern.
- `docs/audits/programmable-agent-rebaseline-audit.md` tracks `PA-006`; update it as this plan closes the remaining acceptance gaps.

## Explicit Scope And Assumptions

- This is an operator-surface completion plan, not a runtime-core plan.
- Breaking changes remain acceptable. Do not add compatibility scaffolding solely to preserve old settings UI behavior.
- Prefer edit/update flows over broad CRUD. Creation and deletion are out of scope unless the implementation reveals a hard blocker.
- Observability in this batch means operator-readable current and recent runtime facts. Do not build a dashboard framework or generic event system first.

## Testing Posture

- every task starts with failing integration or system coverage
- first user-reachable settings pages require browser-backed verification
- validation and owner/admin gating are acceptance behavior, not optional polish
- observability coverage must assert facts produced by the real durable runtime state, not synthetic presenter-only fixtures
- end with one fresh regression sweep across runtime-governance and operator surfaces

## Task 1: Add Provider Limiter Editing To The Existing Provider Surface

**Files:**

- modify:
  - `app/controllers/system/settings/llm_providers_controller.rb`
  - `app/views/system/settings/llm_providers/index.html.erb`
  - `app/views/system/settings/llm_providers/edit.html.erb`
  - `app/views/system/settings/llm_providers/_form.html.erb`
- add or split tests:
  - `test/integration/system_settings_llm_provider_governance_test.rb`
  - `test/system/system_settings_llm_provider_governance_test.rb`

**Must cover:**

- editing `max_concurrent_requests`
- editing `requests_per_minute`
- editing `tokens_per_minute`
- editing `burst_limit`
- editing `backoff_policy`
- preserving the existing API-key and OAuth connection flows while exposing limiter fields on both credential types
- validation errors remain visible on the same browser surface
- owner/admin gating remains enforced

**Verify with:**

`bin/rails test test/integration/system_settings_llm_provider_governance_test.rb test/system/system_settings_llm_provider_governance_test.rb`

## Task 2: Add Instance-Scoped Runtime Settings Surface

**Files:**

- create:
  - `app/controllers/system/settings/runtime_settings_controller.rb`
  - `app/views/system/settings/runtime_settings/show.html.erb`
  - `app/views/system/settings/runtime_settings/edit.html.erb`
  - `app/views/system/settings/runtime_settings/_form.html.erb`
  - `test/integration/system_settings_runtime_settings_test.rb`
  - `test/system/system_settings_runtime_settings_test.rb`
- modify:
  - `config/routes.rb`
  - shared settings navigation if needed

**Must cover:**

- editing `default_worker_concurrency`
- editing `queue_overrides`
- editing `alert_thresholds`
- singleton-row semantics for `RuntimeSetting`
- invalid JSON/object input returns inline validation instead of silent coercion
- owner/admin gating and auth redirects

**Verify with:**

`bin/rails test test/integration/system_settings_runtime_settings_test.rb test/system/system_settings_runtime_settings_test.rb`

## Task 3: Add Execution Location Management Surface

**Files:**

- create:
  - `app/controllers/system/settings/execution_locations_controller.rb`
  - `app/views/system/settings/execution_locations/index.html.erb`
  - `app/views/system/settings/execution_locations/show.html.erb`
  - `app/views/system/settings/execution_locations/edit.html.erb`
  - `app/views/system/settings/execution_locations/_form.html.erb`
  - `test/integration/system_settings_execution_locations_test.rb`
  - `test/system/system_settings_execution_locations_test.rb`
- modify:
  - `config/routes.rb`
  - settings navigation and execution-target linking where needed

**Must cover:**

- listing visible execution locations
- editing `max_concurrent_tasks`
- editing `max_queued_tasks`
- editing `default_timeout_s`
- displaying location metadata needed to understand capacity policy
- surfacing validation failures without losing the edited values

**Verify with:**

`bin/rails test test/integration/system_settings_execution_locations_test.rb test/system/system_settings_execution_locations_test.rb`

## Task 4: Add Workspace Management Surface

**Files:**

- create:
  - `app/controllers/system/settings/workspaces_controller.rb`
  - `app/views/system/settings/workspaces/index.html.erb`
  - `app/views/system/settings/workspaces/show.html.erb`
  - `app/views/system/settings/workspaces/edit.html.erb`
  - `app/views/system/settings/workspaces/_form.html.erb`
  - `test/integration/system_settings_workspaces_test.rb`
  - `test/system/system_settings_workspaces_test.rb`
- modify:
  - `config/routes.rb`
  - execution-target and execution-location surfaces to deep-link into workspace pages

**Must cover:**

- listing workspaces with location context
- editing workspace operator fields that affect runtime selection or safety
- showing capability tags and status clearly enough for operator review
- keeping location/workspace navigation coherent from the existing execution-target inventory

**Verify with:**

`bin/rails test test/integration/system_settings_workspaces_test.rb test/system/system_settings_workspaces_test.rb`

## Task 5: Add Execution Target Override Editing

**Files:**

- modify:
  - `app/controllers/system/settings/execution_targets_controller.rb`
  - `app/views/system/settings/execution_targets/index.html.erb`
  - `app/views/system/settings/execution_targets/show.html.erb`
- create:
  - `app/views/system/settings/execution_targets/edit.html.erb`
  - `app/views/system/settings/execution_targets/_form.html.erb`
  - `test/integration/system_settings_execution_targets_test.rb`
  - `test/system/system_settings_execution_targets_test.rb`
- modify:
  - `config/routes.rb`

**Must cover:**

- editing `max_concurrent_tasks_override`
- editing `max_queued_tasks_override`
- editing `default_timeout_s_override`
- showing inherited-versus-overridden execution-capacity policy on the target detail page
- preserving inventory visibility and target detail behavior already covered by the programmable-agent plan

**Verify with:**

`bin/rails test test/integration/system_settings_execution_targets_test.rb test/integration/execution_target_inventory_test.rb test/system/system_settings_execution_targets_test.rb`

## Task 6: Add Minimal Runtime Governance Observability Surface

**Files:**

- create:
  - `app/controllers/system/settings/runtime_governance_controller.rb`
  - `app/views/system/settings/runtime_governance/show.html.erb`
  - `app/services/runtime_governance/observability_feed.rb`
  - `test/integration/system_settings_runtime_governance_test.rb`
  - `test/integration/runtime_governance_observability_test.rb`
  - `test/system/system_settings_runtime_governance_test.rb`
- modify:
  - `config/routes.rb`
  - settings navigation

**Must cover:**

- current parked waits for `provider_limit`, `execution_capacity`, and `deployment_backoff`
- recent `execution_capacity_denied` outcomes
- recent wakeup or recovery evidence derived from durable waits and leases
- recent provider-limit hits or backoff outcomes derived from durable reservation state
- operator-readable grouping by governed subject without inventing a new event bus

**Verify with:**

`bin/rails test test/integration/system_settings_runtime_governance_test.rb test/integration/runtime_governance_observability_test.rb test/system/system_settings_runtime_governance_test.rb`

## Task 7: Align Docs, Audit Language, And Final Acceptance Evidence

**Files:**

- modify:
  - `docs/plans/2026-03-08-runtime-governance.md`
  - `docs/product/runtime_governance.md`
  - `docs/audits/programmable-agent-rebaseline-audit.md`

**Must cover:**

- Task 6 in the original runtime-governance plan points to this split follow-up instead of pretending to remain one oversized acceptance slice
- product docs describe the operator surfaces that now exist, using `execution_capacity` terminology consistently
- audit evidence for `PA-006` points at the new plan and the implemented verification files

**Verify with:**

`bin/rails test test/integration/system_settings_llm_provider_governance_test.rb test/integration/system_settings_runtime_settings_test.rb test/integration/system_settings_execution_locations_test.rb test/integration/system_settings_workspaces_test.rb test/integration/system_settings_execution_targets_test.rb test/integration/system_settings_runtime_governance_test.rb test/integration/runtime_governance_observability_test.rb`

## Final Verification Sweep

Run fresh after all tasks:

`PARALLEL_WORKERS=1 bin/rails test test/integration/system_settings_llm_provider_governance_test.rb test/system/system_settings_llm_provider_governance_test.rb test/integration/system_settings_runtime_settings_test.rb test/system/system_settings_runtime_settings_test.rb test/integration/system_settings_execution_locations_test.rb test/system/system_settings_execution_locations_test.rb test/integration/system_settings_workspaces_test.rb test/system/system_settings_workspaces_test.rb test/integration/system_settings_execution_targets_test.rb test/system/system_settings_execution_targets_test.rb test/integration/system_settings_runtime_governance_test.rb test/system/system_settings_runtime_governance_test.rb test/integration/runtime_governance_observability_test.rb test/integration/execution_target_inventory_test.rb test/integration/llm_providers_test.rb test/integration/system_settings_automations_test.rb test/system/system_settings_automations_test.rb test/services/runtime_governance/provider_budget_reservations_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/services/runtime_governance/runtime_waits_test.rb test/integration/execution_capacity_enforcement_test.rb`

If any operator surface materially changes in the browser, rerun targeted browser evidence through the repo's existing browser-backed system tests before closing the batch.

This sweep passed on 2026-03-10 and is the final acceptance evidence for this split plan.
