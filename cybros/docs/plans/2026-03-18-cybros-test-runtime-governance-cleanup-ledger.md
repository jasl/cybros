# Cybros Test Runtime Governance Cleanup Ledger

## Active Truth Sources

Current cleanup/process truth sources:

- `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-design.md`
- `cybros/docs/plans/2026-03-17-cybros-main-app-cleanup-ledger.md`
- `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup-design.md`
- `cybros/docs/plans/2026-03-18-cybros-test-runtime-governance-cleanup.md`

Current product/runtime truth sources to preserve as active:

- `cybros/app/models/agent.rb`
- `cybros/app/models/recognized_deployment.rb`
- `cybros/app/services/runtime_governance/execution_capacity_resolver.rb`
- `cybros/app/services/runtime_governance/execution_capacity_enforcer.rb`
- `cybros/test/test_helper.rb`

Current scope anchors:

- `cybros/test/models/agent_test.rb`
- `cybros/test/models/recognized_deployment_test.rb`
- `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb`
- `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb`
- `cybros/test/integration/execution_capacity_enforcement_test.rb`
- `cybros/test/integration/runtime_governance_observability_test.rb`
- `cybros/test/integration/system_settings_runtime_governance_test.rb`

Old nouns / removal targets for this cleanup:

- local helper names that call an `Agent` fixture `program`
- local helper names that call a synthetic execution profile an `execution_target`
- runtime helper hashes that expose `program` or `target` as active scoped truth when they are only legacy naming wrappers
- scoped test narratives that still explain execution capacity through fake targets rather than agent-owned capacity

## Target Scope

This pass targets the runtime-governance and agent-runtime-fixture cluster under `cybros/test/`, specifically:

- `cybros/test/models/agent_test.rb`
- `cybros/test/models/recognized_deployment_test.rb`
- `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb`
- `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb`
- `cybros/test/integration/execution_capacity_enforcement_test.rb`
- `cybros/test/integration/runtime_governance_observability_test.rb`
- `cybros/test/integration/system_settings_runtime_governance_test.rb`
- `cybros/test/test_helper.rb` when a scoped helper decision is required

## P0 Findings

1. Anchor model tests still present `Agent` fixtures as legacy `program` records and still construct synthetic execution targets to explain agent-owned capacity.
   Evidence:
   - `cybros/test/models/agent_test.rb:5`
   - `cybros/test/models/agent_test.rb:6`
   - `cybros/test/models/agent_test.rb:8`
   - `cybros/test/models/agent_test.rb:118`
   - `cybros/test/models/agent_test.rb:133`
   - `cybros/test/models/recognized_deployment_test.rb:117`
   - `cybros/test/models/recognized_deployment_test.rb:118`
   - `cybros/test/models/recognized_deployment_test.rb:153`
   Action: `delete` / `Rails-shaped simplify`
   Notes: Cleaned in Round 2. Re-scan now leaves only explicit negative coverage for removed helper keywords in `agent_test`.

2. Shared helper truth in `test/test_helper.rb` still exposes execution-profile fixture builders that can reintroduce the obsolete target model into new tests.
   Evidence:
   - `cybros/test/test_helper.rb:372`
   - `cybros/test/test_helper.rb:389`
   - `cybros/test/test_helper.rb:403`
   - `cybros/test/test_helper.rb:420`
   - `cybros/test/test_helper.rb:547`
   - `cybros/test/test_helper.rb:800`
   Action: `keep` for now
   Notes: These helpers are still active outside the scoped cluster. The current pass should avoid deleting them globally unless the broader consumer set is migrated. Re-audit must confirm whether scoped files still rely on them.

## P1 Findings

1. Runtime-governance service and execution-capacity integration tests still build the scoped world through `create_program!` helpers and runtime hashes keyed as `program`.
   Evidence:
   - `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb:5`
   - `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb:29`
   - `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb:90`
   - `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb:101`
   - `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb:111`
   - `cybros/test/integration/execution_capacity_enforcement_test.rb:193`
   - `cybros/test/integration/execution_capacity_enforcement_test.rb:206`
   - `cybros/test/integration/execution_capacity_enforcement_test.rb:214`
   Action: `delete` / `Rails-shaped simplify`
   Notes: Cleaned in Round 3. The scoped files now expose `agent`, `runtime_binding`, and `recognized_deployment` directly.

## P2 Findings

1. Runtime-governance observability tests still describe governed agent subjects as `program` fixtures and preserve that naming inside helper APIs.
   Evidence:
   - `cybros/test/integration/runtime_governance_observability_test.rb:82`
   - `cybros/test/integration/runtime_governance_observability_test.rb:204`
   - `cybros/test/integration/runtime_governance_observability_test.rb:219`
   - `cybros/test/integration/runtime_governance_observability_test.rb:238`
   - `cybros/test/integration/runtime_governance_observability_test.rb:367`
   Action: `Rails-shaped simplify`
   Notes: Cleaned in Round 4. Remaining `deployment` hits in this file are current API parameter names and the live `RecognizedDeployment` model.

## P3 Findings

1. The scoped system runtime-governance test still manufactures a local `execution_target` helper and threads that noun through wait/denial setup.
   Evidence:
   - `cybros/test/integration/system_settings_runtime_governance_test.rb:22`
   - `cybros/test/integration/system_settings_runtime_governance_test.rb:64`
   - `cybros/test/integration/system_settings_runtime_governance_test.rb:81`
   - `cybros/test/integration/system_settings_runtime_governance_test.rb:144`
   - `cybros/test/integration/system_settings_runtime_governance_test.rb:178`
   Action: `delete` / `Rails-shaped simplify`
   Notes: Cleaned in Round 5. Remaining `deployment` hits are current runtime-binding terminology, not legacy target truth.

2. Adjacent test-tree residue still exists outside this scope.
   Evidence:
   - `cybros/test/system/system_settings_automations_test.rb:93`
   - `cybros/test/system/system_settings_runtime_governance_test.rb:88`
   - `cybros/test/script/live_acceptance/agent_root_workspace_test.rb:262`
   - `cybros/test/integration/programmable_agent_execution_test.rb:180`
   Action: `keep`
   Notes: These files remain out of scope for this pass. Re-audit should confirm they stay logged as adjacent residue rather than silently treated as cleaned.

## Delete Candidates

- local `create_program!` helpers inside the scoped files
- local `create_execution_target!` helpers inside the scoped files
- scoped runtime hashes that expose `:program` or `:target` only because of legacy fixture naming

## Archive Candidates

- none identified at baseline

## Keep-With-Reason Candidates

1. Explicit negative assertions that removed target/program columns stay absent.
   Evidence:
   - `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb:12`
   - `cybros/test/integration/execution_capacity_enforcement_test.rb:188`
   Reason: these assertions prove the obsolete columns and scope identifiers remain removed from active snapshots.

2. Shared execution-profile fixture builders in `test/test_helper.rb`.
   Evidence:
   - `cybros/test/test_helper.rb:372`
   - `cybros/test/test_helper.rb:389`
   - `cybros/test/test_helper.rb:403`
   - `cybros/test/test_helper.rb:800`
   Reason: active consumers outside this scoped pass still depend on them. Delete only in a broader follow-up that migrates those callers.

## Round Closeout Notes

### Round 1

- PostgreSQL is available (`pg_isready` returned accepting connections).
- Branch state at start: `main...origin/main [ahead 51]`.
- No unrelated tracked changes were present in `git status --short`.
- Baseline discovery confirms the scoped cluster is still misleading developers in two distinct ways:
  - anchor tests and local helpers still call `Agent` fixtures `program`
  - selected model/system files still manufacture synthetic `execution_target` profiles to narrate agent-owned capacity
- Baseline discovery also confirms one important keep decision:
  - negative assertions about missing `execution_target_*` keys/columns still provide useful regression coverage and should not be removed as false positives

### Round 2

- Cleaned the anchor model-test truth sources in:
  - `cybros/test/models/agent_test.rb`
  - `cybros/test/models/recognized_deployment_test.rb`
- Deleted local `create_execution_target!` helper scaffolding from both files.
- Renamed the local fixture helper in `agent_test` from `create_program!` to `create_agent_fixture!`.
- Simplified the recognized-deployment runtime fixture so it no longer exports fake `program` / `target` keys.
- Kept explicit negative coverage for removed helper keywords:
  - `agent_program:`
  - `default_execution_target:`
  - `program:`
  - `execution_target:`
- Verification command that passed during this round:
  - `bin/rails test test/models/agent_test.rb test/models/recognized_deployment_test.rb`
- Re-scan after the round:
  - `rg -n "create_program!|create_execution_target!|execution_profile:|fixture.program|agent_programs" cybros/test/models/agent_test.rb cybros/test/models/recognized_deployment_test.rb` returned no hits.
  - Remaining old-keyword hits in the anchor files are limited to the explicit rejection coverage listed above.

### Round 3

- Cleaned the runtime-governance service/integration cluster in:
  - `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb`
  - `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb`
  - `cybros/test/integration/execution_capacity_enforcement_test.rb`
- Renamed local fixture helpers from `create_program!` to `create_governed_agent!`.
- Renamed local binding helpers from `create_deployment!` to `create_runtime_binding!`.
- Simplified the runtime fixture hashes so they no longer export a stale `program` key.
- Verification command that passed during this round:
  - `bin/rails test test/services/runtime_governance/execution_capacity_resolver_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/integration/execution_capacity_enforcement_test.rb`
- Re-scan after the round:
  - `rg -n "create_program!|fixture.program|fetch\\(:program\\)|create_deployment!|\\bprogram\\b" cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb cybros/test/integration/execution_capacity_enforcement_test.rb` returned no hits.
  - Remaining `deployment` hits in these files are current API parameter/field names around runtime bindings, not stale truth sources.

### Round 4

- Cleaned the observability cleanup batch in:
  - `cybros/test/integration/runtime_governance_observability_test.rb`
- Renamed local helper narratives from `create_program!` to `create_governed_agent!`.
- Renamed the local runtime-binding helper from `create_deployment!` to `create_runtime_binding!`.
- Updated governed subject labels from stale `program` / `target` wording to `agent`.
- Verification command that passed during this round:
  - `bin/rails test test/integration/runtime_governance_observability_test.rb`
- Re-scan after the round:
  - `rg -n "create_program!|fixture.program|Blocked program|Recovered program|Backoff program|Stale target|\\bprogram\\b" cybros/test/integration/runtime_governance_observability_test.rb` returned no hits.
  - Remaining `deployment` hits are limited to the live `RecognizedDeployment` model and current API parameter names.

### Round 5

- Cleaned the scoped system runtime-governance surface in:
  - `cybros/test/integration/system_settings_runtime_governance_test.rb`
- Deleted the local `create_execution_target!` helper and replaced it with direct agent-capacity setup.
- Renamed the local agent fixture helper from `create_program!` to `create_governed_agent!`.
- Renamed the local runtime-binding helper from `create_deployment!` to `create_runtime_binding!`.
- Verification command that passed during this round:
  - `bin/rails test test/integration/system_settings_runtime_governance_test.rb`
- Re-scan after the round:
  - `rg -n "create_execution_target!|execution_target|create_program!|fixture.program|Observability program|\\bprogram\\b" cybros/test/integration/system_settings_runtime_governance_test.rb` returned no hits.
  - Remaining `deployment` hits are limited to the runtime-binding helper/fields and the local backoff subject variable in the rendered-UI assertion.

### Round 6 Retrospective Re-Audit

- Re-ran the scoped baseline discovery query across:
  - `cybros/test/models/agent_test.rb`
  - `cybros/test/models/recognized_deployment_test.rb`
  - `cybros/test/services/runtime_governance/execution_capacity_resolver_test.rb`
  - `cybros/test/services/runtime_governance/execution_capacity_enforcer_test.rb`
  - `cybros/test/integration/execution_capacity_enforcement_test.rb`
  - `cybros/test/integration/runtime_governance_observability_test.rb`
  - `cybros/test/integration/system_settings_runtime_governance_test.rb`
  - `cybros/test/test_helper.rb`
- Re-audit result:
  - scoped cleaned files no longer contain local `create_program!`, local `create_execution_target!`, or stale `fixture.program` namespaces
  - remaining scoped hits are intentional:
    - explicit rejection coverage in `cybros/test/models/agent_test.rb`
    - shared `execution_profile` helper signatures in `cybros/test/test_helper.rb`, kept because broader active consumers still exist
- Fresh aggregate targeted verification passed:
  - `bin/rails test test/models/agent_test.rb test/models/recognized_deployment_test.rb test/services/runtime_governance/execution_capacity_resolver_test.rb test/services/runtime_governance/execution_capacity_enforcer_test.rb test/integration/execution_capacity_enforcement_test.rb test/integration/runtime_governance_observability_test.rb test/integration/system_settings_runtime_governance_test.rb`
- Fresh broader verification passed:
  - `bin/rails test`
  - Result: `2054 runs, 10604 assertions, 0 failures, 0 errors, 0 skips`
- Re-audit also found adjacent residue still outside this pass:
  - `cybros/test/system/system_settings_runtime_governance_test.rb`
  - `cybros/test/system/system_settings_automations_test.rb`
  - `cybros/test/script/live_acceptance/agent_root_workspace_test.rb`
  - `cybros/test/integration/programmable_agent_execution_test.rb`
  These remain explicit defer items rather than silent misses.

## Reusable Strategy Lessons

- Do not treat every `program` string as cleanup residue. In this codebase, the real problem is test truth sources that rename an `Agent` fixture to `program`, not every internal use of a variable named `program`.
- Negative assertions about absent old columns are often valuable keeps, not cleanup failures.
- Shared helper deletion should be gated by current consumer scans; otherwise a local cleanup turns into an unscoped suite breakage.
- Full-suite verification is worth running after test-truth cleanup even when only local fixture names changed; it confirms whether the new naming/model alignment leaked into broader shared helper expectations.
