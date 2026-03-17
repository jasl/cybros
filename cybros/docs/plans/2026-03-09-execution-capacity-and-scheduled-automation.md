# Execution Capacity And Scheduled Automation Implementation Plan

> Historical note (2026-03-10): the `execution_capacity` half of this implementation record remains valid, but its scheduled-automation runtime description was superseded by [`2026-03-10-automation-conversation-convergence.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/plans/2026-03-10-automation-conversation-convergence.md). Current scheduled automation creates or reuses execution conversations and runs [`Automations::ExecuteConversationJob`](/Users/jasl/Workspaces/Cybros/cybros/cybros/app/jobs/automations/execute_conversation_job.rb), not `AutomationRun` plus `ExecuteRunJob`.

**Status:** implemented on 2026-03-09 on `codex/programmable-agent-rebaseline`.

**Outcome:** this batch closed `PA-011` and `PA-012`. The governor naming is now `execution_capacity` everywhere with no compatibility shims. Scheduled automation runs through `ActiveJob + Solid Queue`: a recurring dispatch job finds due automations, dispatch creates or reuses an `AutomationRun`, and a dedicated execute job atomically claims the queued run before invoking the existing orchestrator. Execution-capacity admission happens at the DAG claim boundary, not during draft finalization. `waiting_for_capacity` remains a derived runtime state from durable `RuntimeWait` facts, not a new persisted `ConversationRun.state`. Capacity release, cancel, and running-lease reclaim all release execution capacity and wake the oldest parked waiter by clearing retry gating and kicking the graph.

## Cross-Plan Dependencies

- `2026-03-08-runtime-governance.md` owns the governor, lease, and wait primitives being renamed and enforced.
- `2026-03-10-automation-conversation-convergence.md` now owns the current production dispatch semantics and acceptance surface for scheduled automation.
- `docs/audits/programmable-agent-rebaseline-audit.md` tracks `PA-011` and `PA-012`; update it as findings are closed.

## Explicit Scope And Assumptions

- This plan intentionally implements `PA-011` and `PA-012`.
- `PA-006` remained out of scope for this batch. It was later closed by [`docs/archive/plans/2026-03/2026-03-09-runtime-governance-operator-surfaces.md`](/Users/jasl/Workspaces/Cybros/cybros/cybros/docs/archive/plans/2026-03/2026-03-09-runtime-governance-operator-surfaces.md), so do not treat this plan as the current status source for that finding.
- Breaking changes are allowed. Do not preserve legacy governor naming or runtime compatibility paths.
- Resetting local databases is acceptable. Prefer one-step clean naming over transitional aliases or dual-read logic.

## Testing Posture

- follow TDD for every behavior change
- replace fake service-only acceptance with real runtime-path coverage where this plan touches execution
- keep automation coverage browser-backed when operator-visible behavior changes
- finish with a fresh regression sweep over runtime-governance, automation, and programmable-agent browser flows

## Task 1: Finalize Execution Capacity Naming Everywhere

**Files:**

- rename or replace:
  - `app/services/runtime_governance/execution_capacity_resolver.rb`
  - `app/services/runtime_governance/execution_capacity_enforcer.rb`
  - legacy governor snapshot, wait-reason, and error-code references
- update:
  - `app/models/run_draft.rb`
  - `app/models/runtime_wait.rb`
  - `app/services/run_drafts/discard_service.rb`
  - runtime-governance tests, run-draft tests, integration tests, audit/docs references

**Must cover:**

- governor snapshot key becomes `execution_capacity`
- wait reason becomes `execution_capacity`
- service/class names become `ExecutionCapacityResolver` / `ExecutionCapacityEnforcer`
- error codes and assertion names stop mentioning quota
- docs and audit language stop mentioning quota for this governor

**Verify with:**

`bin/rails test test/models/run_draft_test.rb test/services/runtime_governance/execution_capacity_resolver_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/services/runtime_governance/runtime_waits_test.rb`

## Task 2: Add Production Jobs For Scheduled Automation Dispatch And Execution

**Files:**

- create:
  - `app/jobs/automations/dispatch_due_job.rb`
  - `app/jobs/automations/execute_run_job.rb`
  - job tests under `test/jobs/automations/`
- modify:
  - `app/services/automations/scheduler.rb`
  - `app/services/automations/dispatch.rb`
  - `config/recurring.yml`

**Must cover:**

- a recurring job invokes `Automations::Scheduler.dispatch_due!`
- newly created scheduled `AutomationRun` records enqueue `Automations::ExecuteRunJob`
- existing runs found by `dispatch_key` do not enqueue duplicate execution work
- execution job atomically claims queued runs before orchestration
- scheduled dispatch remains idempotent across retries

**Verify with:**

`bin/rails test test/services/automations/dispatch_test.rb test/integration/automation_scheduler_flow_test.rb test/jobs/automations/dispatch_due_job_test.rb test/jobs/automations/execute_run_job_test.rb`

## Task 3: Replace Manual Scheduled-Run Starts With Real Production Flow

**Files:**

- modify:
  - `app/services/automations/run_orchestrator.rb` only if needed for execute-job idempotency or clearer failure semantics
  - automation integration/system tests that currently call `Automations::RunOrchestrator.start!` manually
- add or replace:
  - targeted integration coverage for recurring dispatch -> execute job -> orchestrator
  - browser-backed coverage for the operator automation surfaces after automatic scheduling

**Must cover:**

- scheduled automation reaches draft planning and finalization through jobs, not test-only direct service calls
- `queued` scheduled runs automatically transition into `awaiting_approval`, `running`, `completed`, or `failed` through production wiring
- automation operator surfaces show states produced by the real scheduled path
- scheduled-flow acceptance no longer depends on manual test-side `RunOrchestrator.start!`

**Verify with:**

`bin/rails test test/integration/automation_run_draft_flow_test.rb test/integration/automation_scheduler_flow_test.rb test/integration/automation_failure_recovery_test.rb test/integration/system_settings_automations_test.rb test/system/system_settings_automations_test.rb`

## Task 4: Enforce Execution Capacity At The DAG Claim Boundary

**Files:**

- modify:
  - `lib/dag/scheduler.rb`
  - `app/jobs/dag/tick_graph_job.rb` if scheduler integration needs explicit retry/kick behavior
  - `lib/dag/runner.rb`
  - `app/models/conversation_run.rb`
  - runtime-governance services for capacity admit/release
- add:
  - helper(s) that resolve the `ConversationRun` for a programmable agent node
  - regression coverage for claim-time admit, park, deny, release, and wakeup

**Must cover:**

- programmable runs admit capacity before a node is claimed for real execution
- blocked runs park with `RuntimeWait(reason_type: "execution_capacity")`
- parked capacity waits derive `waiting_for_capacity` without adding a new persisted run state
- denied capacity when backlog is full becomes a terminal run failure, not an auto-retry
- successful and terminal execution paths release leases exactly once

**Verify with:**

`bin/rails test test/lib/dag/scheduler_test.rb test/lib/dag/runner_test.rb test/jobs/dag/tick_graph_job_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/programmable_agent_execution_test.rb`

## Task 5: Wake Parked Capacity Waits On Release And Sweep Regressions

**Files:**

- modify:
  - `app/services/runtime_governance/runtime_waits.rb`
  - capacity release paths
  - DAG retry / kick integration where needed
  - automation and runtime-governance acceptance docs
- update:
  - `docs/product/runtime_governance.md`
  - `docs/product/automation.md`
  - `docs/audits/programmable-agent-rebaseline-audit.md`

**Must cover:**

- capacity release wakes the oldest parked waiter for the same governed subject
- `claim_after_at` or equivalent retry gating is cleared so the graph can retry promptly
- `retry_at` remains the fallback path if immediate wakeup is missed
- final acceptance evidence reflects the real scheduled + capacity-constrained runtime path

**Verify with:**

`bin/rails test test/services/runtime_governance/runtime_waits_test.rb test/jobs/dag/tick_graph_job_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/automation_scheduler_flow_test.rb`

## Final Verification Sweep

Run fresh after all tasks, from a clean test database if needed:

`PARALLEL_WORKERS=1 bin/rails test test/models/run_draft_test.rb test/services/runtime_governance/execution_capacity_resolver_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/services/runtime_governance/runtime_waits_test.rb test/services/automations/dispatch_test.rb test/jobs/automations/dispatch_due_job_test.rb test/jobs/automations/execute_run_job_test.rb test/jobs/dag/tick_graph_job_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/automation_scheduler_flow_test.rb test/integration/automation_run_draft_flow_test.rb test/integration/automation_failure_recovery_test.rb test/integration/system_settings_automations_test.rb test/system/system_settings_automations_test.rb test/integration/programmable_agent_execution_test.rb test/lib/dag/running_lease_reclaimer_test.rb`

If browser/operator surfaces changed materially, also rerun targeted browser evidence:

`bin/ci_e2e test/e2e/programmable_agent_approval_resume.spec.ts test/e2e/programmable_agent_target_switch.spec.ts`
