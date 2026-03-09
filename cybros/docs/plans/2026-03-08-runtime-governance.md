# Runtime Governance Implementation Plan

**Goal:** implement first-class provider limits, job throughput settings, execution capacity, and durable runtime waits.

**Architecture:** keep the three governors separate. Provider admission uses durable budget reservations. Execution admission uses durable capacity leases. Blocked work parks without monopolizing job workers. `deployment_backoff` remains a wait path, not a fourth governor.

## Cross-Plan Dependencies

- This plan owns the executable schema and settings surfaces for `ExecutionLocation`, `Workspace`, and `ExecutionTarget`.
- `2026-03-09-agent-deployment-connection.md` consumes those models for target inventory APIs, switch policy, and composer selectors.
- `2026-03-09-automation-runtime.md` consumes the same admission and wait primitives for scheduled work.

## Testing Posture

- model and schema work starts with model tests
- admission and wait logic needs service or integration coverage
- real-flow enforcement needs targeted integration tests
- operator settings need browser coverage only when the surface first becomes user-reachable

## Task 1: Add Governance And Execution-Domain Schema

**Files:**

- modify or replace provider credential migration and model
- create runtime-settings migration and model
- modify execution-location, workspace, and execution-target migrations and models
- update `db/schema.rb`
- add model tests for provider credentials, runtime settings, execution locations, workspaces, and execution targets

**Must cover:**

- credential-scoped limiter fields
- instance-scoped runtime settings
- explicit quota and policy inputs on execution locations and targets
- location/workspace ownership constraints
- one active credential per `provider_key`

**Verify with:**

`bin/rails test test/models/llm_provider_credential_test.rb test/models/runtime_setting_test.rb test/models/execution_location_test.rb test/models/workspace_test.rb test/models/execution_target_test.rb`

## Task 2: Resolve Governor Facts During Draft Planning

**Files:**

- create runtime-governance resolver services
- modify draft-opening or runtime-resolution services
- update run-draft and run snapshot tests

**Must cover:**

- provider credential resolution
- location-first quota resolution with target override
- snapshotting resolved governor facts onto drafts
- re-resolution after accepted target changes
- use by both conversation and automation entrypoints

**Verify with:**

`bin/rails test test/models/run_draft_test.rb test/services/runtime_governance/provider_credential_limiter_test.rb test/services/runtime_governance/execution_capacity_resolver_test.rb`

## Task 3: Implement Durable Admission Primitives And Waits

**Files:**

- create provider-budget reservation service and persistence
- create execution-capacity lease service and persistence
- create runtime-wait service and persistence
- add integration coverage for acquire, release, deny, and recovery

**Must cover:**

- atomic acquire
- explicit release or settlement
- crash recovery and reconciliation
- durable request identifiers
- parked waits for `provider_limit`, `execution_capacity`, and `deployment_backoff`

**Verify with:**

`bin/rails test test/services/runtime_governance/provider_budget_reservations_test.rb test/services/runtime_governance/execution_capacity_leases_test.rb test/services/runtime_governance/runtime_waits_test.rb`

## Task 4: Enforce Provider Limits Around LLM Calls

**Files:**

- modify provider-call paths in AgentCore or Cybros runtime services
- extend observability hooks
- add targeted integration and E2E coverage

**Must cover:**

- permit acquisition before remote provider calls
- durable provider-request identifiers
- reservation settlement after completion
- durable parking instead of worker spin when blocked
- limiter-hit observability

**Verify with:**

`bin/rails test test/lib/agent_core/resources/provider/rate_limit_enforcement_test.rb test/integration/provider_credential_limiter_flow_test.rb`

## Task 5: Enforce Execution Capacity Around Nexus-Bound Work

**Files:**

- modify execution-planning services
- integrate execution-capacity leases before Nexus-bound work
- add targeted integration coverage

**Must cover:**

- location quota by default
- target override when present
- durable execution-request identifiers
- lease recovery before replay
- capacity-denied work parking without holding worker slots

**Verify with:**

`bin/rails test test/services/runtime_governance/execution_capacity_enforcer_test.rb test/integration/execution_capacity_enforcement_test.rb`

## Task 6: Add Operator Settings Surfaces And Observability

**Files:**

- system settings controllers and views for provider governance and runtime settings
- system settings surfaces for execution locations and workspaces
- observability/event projection code
- integration and browser tests for the first user-reachable surfaces

**Must cover:**

- editing limiter fields
- editing runtime job settings
- editing execution-location and workspace records
- visibility into limiter hits, quota denials, waits, and recovery

**Verify with:**

`bin/rails test test/integration/system_settings_runtime_governance_test.rb test/integration/runtime_governance_observability_test.rb`
