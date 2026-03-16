# Repo-Root Skill Batch Install Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend the protected skill installer so a GitHub repo root can resolve to a batch install of all discovered skills with one approval, one atomic promotion, and next-top-level-turn refresh.

**Architecture:** Keep `skills_install` as the only protected installer surface and add a repo-root batch mode for `source_kind=github` calls that provide `repo` without `path`. The installer will stage the repo once, discover candidate skill roots deterministically, validate the full batch before approval, then atomically snapshot and promote the entire batch into `<agent-root>/skills/`. Bundled `claw`, approval payloads, provenance, prompt guidance, and live acceptance all stay aligned with this single-tool path.

**Tech Stack:** Ruby on Rails, Pathname/FileUtils, git sparse checkout staging, agent-owned tool registry, protected-path policy, bundled `claw`, Rails tests, real-model live acceptance in `development`

**Execution Root:** `/Users/jasl/Workspaces/Cybros/cybros/cybros`

**Design Source:** `docs/plans/2026-03-16-repo-root-skill-batch-install-design.md`

**Execution Assumptions:**
- this is a breaking product adjustment on top of the protected installer already in progress
- do not add a second repo-install tool; keep `skills_install` as the single protected installer surface
- repo-root GitHub input means "install all discovered skills from this repo"
- repo-root installs are one-approval, fail-closed, atomic batch installs
- if prior installed skills interfere with live proof, they may be removed manually in `development` before rerunning acceptance

---

### Task 1: Lock Repo-Root Batch Discovery And Failure Rules With Failing Tests

**Files:**
- Modify: `app/services/agents/skill_installation/source_fetcher.rb`
- Modify: `app/services/agents/skill_installation_service.rb`
- Modify: `test/services/agents/skill_installation_service_test.rb`
- Modify: `test/lib/cybros/agent_owned_tools_test.rb`

**Step 1: Write the failing test**

Cover:

- `skills_install` with `source_kind=github` and `repo` but no `path` enters repo-root batch mode
- phase-1 discovery finds `skills/*/SKILL.md` and `skills/.system/*/SKILL.md`
- fallback discovery only runs when phase 1 finds no candidates
- repo-root candidate ordering is deterministic
- repo-root batches fail closed when no candidates are found

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb test/lib/cybros/agent_owned_tools_test.rb`

Expected: FAIL because repo-root batch discovery is not implemented and the tool contract still assumes one skill per GitHub install.

**Step 3: Write minimal implementation**

Implement only enough discovery and contract plumbing to make the tests pass:

- repo-root batch mode detection
- preferred-layout discovery
- fallback limited-depth discovery
- deterministic candidate ordering
- stable failure when no skills are discovered

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb test/lib/cybros/agent_owned_tools_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/skill_installation/source_fetcher.rb app/services/agents/skill_installation_service.rb test/services/agents/skill_installation_service_test.rb test/lib/cybros/agent_owned_tools_test.rb
git commit -m "test: lock repo-root skill batch discovery rules"
```

### Task 2: Build Repo-Root Candidate Normalization And Full-Batch Validation

**Files:**
- Modify: `app/services/agents/skill_installation_service.rb`
- Modify: `app/services/agents/skill_installation/manifest.rb`
- Modify: `test/services/agents/skill_installation_service_test.rb`

**Step 1: Write the failing test**

Cover:

- each discovered candidate resolves to one skill root and one install name
- repo-root install names default to the skill-root basename
- declared skill name in `SKILL.md` must match the root basename
- duplicate candidate names fail the full batch
- platform collisions fail the full batch
- existing installed skill collisions fail the full batch when `replace=false`
- invalid candidate entries fail the full batch

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb`

Expected: FAIL because repo-root mode does not yet normalize and validate the entire batch before approval.

**Step 3: Write minimal implementation**

Implement:

- repo-root candidate normalization
- batch-wide install-name validation
- batch-wide duplicate detection
- platform and existing-destination collision checks across the whole batch
- declared-name-vs-directory-name validation

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/skill_installation_service.rb app/services/agents/skill_installation/manifest.rb test/services/agents/skill_installation_service_test.rb
git commit -m "feat: validate repo-root skill install batches"
```

### Task 3: Add Batch Approval Payload And Unified Batch Result Shape

**Files:**
- Modify: `lib/cybros/agent_owned_tools.rb`
- Modify: `lib/cybros/agent_runtime_resolver.rb`
- Modify: `test/lib/cybros/agent_owned_tools_test.rb`
- Modify: `test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`
- Modify: `test/integration/programmable_agent_tool_routing_test.rb`

**Step 1: Write the failing test**

Cover:

- `skills_install` schema and description clearly support repo-root GitHub input
- repo-root installs still require confirmation
- batch approval payload includes mode, repo/ref, candidate count, and per-candidate summaries
- success output normalizes around `mode`, `installed_count`, and `installed_skills[]`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/agent_owned_tools_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_tool_routing_test.rb`

Expected: FAIL because the public surface and approval serialization still assume single-skill installation only.

**Step 3: Write minimal implementation**

Implement:

- repo-root batch language in the `skills_install` tool schema/description
- unified batch-shaped success payload
- approval payload enrichment for repo-root installs
- no relaxation of confirmation rules

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/agent_owned_tools_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_tool_routing_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add lib/cybros/agent_owned_tools.rb lib/cybros/agent_runtime_resolver.rb test/lib/cybros/agent_owned_tools_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_tool_routing_test.rb
git commit -m "feat: expose repo-root batch installs on the tool surface"
```

### Task 4: Implement Atomic Batch Snapshot, Promote, Rollback, And Provenance

**Files:**
- Modify: `app/services/agents/skill_installation_service.rb`
- Modify: `app/services/agents/skill_installation/provenance_store.rb`
- Modify: `test/services/agents/skill_installation_service_test.rb`
- Modify: `test/scenarios/dag/agent_tool_calls_flow_test.rb`

**Step 1: Write the failing test**

Cover:

- repo-root installs snapshot every replaced skill before promotion
- promotion is atomic across the full batch
- a failure during promotion rolls back the full batch
- provenance is written per installed skill and includes batch context
- next-top-level-turn refresh still occurs once after the batch succeeds

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: FAIL because batch installs do not yet snapshot and promote as one transaction.

**Step 3: Write minimal implementation**

Implement:

- batch temp/live path planning
- pre-promotion snapshot of all replaced skills
- deterministic batch promotion order
- rollback to the pre-install state on any failure
- per-skill provenance with batch metadata

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/skill_installation_service.rb app/services/agents/skill_installation/provenance_store.rb test/services/agents/skill_installation_service_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb
git commit -m "feat: atomically promote repo-root skill batches"
```

### Task 5: Wire Repo-Root Batch Execution Through Bundled `claw`

**Files:**
- Modify: `agents/claw/lib/cybros/agents/claw/tools/skill_tools.rb`
- Modify: `agents/claw/lib/cybros/agents/claw/application.rb`
- Modify: `agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Cover:

- `claw` advertises repo-root-capable `skills_install`
- `claw` executes repo-root batch installs through the same protected installer path
- repo-root batch failures surface stable error codes
- repo-root batch successes return the normalized batch result shape

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because bundled `claw` does not yet lock repo-root batch behavior in its contract tests.

**Step 3: Write minimal implementation**

Implement:

- repo-root batch handling in the `claw` skill tool path
- any required tool catalog wording updates
- no separate repo-install tool

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add agents/claw/lib/cybros/agents/claw/tools/skill_tools.rb agents/claw/lib/cybros/agents/claw/application.rb agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: support repo-root skill batches in claw"
```

### Task 6: Bias The Agent Toward Repo-Root Batch Installs

**Files:**
- Modify: `skills/.system/skill-installer/SKILL.md`
- Modify: `test/integration/programmable_agent_prompt_builder_test.rb`
- Modify: `test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

**Step 1: Write the failing test**

Cover:

- the built-in installer guidance tells the agent to use `skills_install` for GitHub repo roots
- repo-root GitHub input is described as "install all discovered skills"
- the prompt surface still preserves progressive disclosure instead of encouraging model-authored byte reconstruction

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/programmable_agent_prompt_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

Expected: FAIL because the installer guidance still only explains single-skill installs.

**Step 3: Write minimal implementation**

Update the built-in guidance so the preferred path for repo URLs is:

- normalize to `repo`
- call `skills_install`
- let the tool batch-install discovered skills
- avoid `read`/`write` reconstruction for installation

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/programmable_agent_prompt_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add skills/.system/skill-installer/SKILL.md test/integration/programmable_agent_prompt_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb
git commit -m "feat: guide agents toward repo-root skill batch installs"
```

### Task 7: Add Repo-Root Live Acceptance Scenarios

**Files:**
- Modify: `script/live_acceptance/agent_root_workspace.rb`
- Modify: `test/script/live_acceptance/agent_root_workspace_test.rb`
- Modify: `test/script/live_acceptance/skill_installer_test.rb`

**Step 1: Write the failing test**

Cover:

- local fixture repo-root install of multiple skills through one approval
- all installed skills are visible on the next top-level turn
- invalid candidate in a repo-root batch causes full failure
- colliding candidate in a repo-root batch causes full failure
- no partial live install remains after a failed repo-root batch

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/script/live_acceptance/skill_installer_test.rb test/script/live_acceptance/agent_root_workspace_test.rb`

Expected: FAIL because live acceptance does not yet model repo-root batch installs.

**Step 3: Write minimal implementation**

Extend the harness with:

- local multi-skill repo fixtures
- repo-root batch approval-driving support
- per-batch proof reporting
- failure assertions for atomicity

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/script/live_acceptance/skill_installer_test.rb test/script/live_acceptance/agent_root_workspace_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add script/live_acceptance/agent_root_workspace.rb test/script/live_acceptance/agent_root_workspace_test.rb test/script/live_acceptance/skill_installer_test.rb
git commit -m "test: cover repo-root skill batch installs in live acceptance"
```

### Task 8: Run Full Verification And Real `development` Proof

**Files:**
- Modify: `docs/reports/2026-03-16-agent-root-workspace-proof.md`
- Create: `docs/reports/2026-03-16-repo-root-skill-batch-proof.md`

**Step 1: Run deterministic verification**

Run:

```bash
bin/rails test test/services/agents/skill_installation_service_test.rb test/services/agents/skill_catalog_test.rb test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_owned_tools_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_tool_routing_test.rb test/integration/programmable_agent_prompt_builder_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb test/script/live_acceptance/skill_installer_test.rb test/script/live_acceptance/agent_root_workspace_test.rb
```

Expected: PASS

**Step 2: Run bundled `claw` contract verification**

Run:

```bash
bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb
```

Expected: PASS

**Step 3: Run real-model live acceptance**

Run:

```bash
bin/rails runner script/live_acceptance/agent_root_workspace.rb --model-ref openrouter/openai-gpt-5.4 --runs 3 --report-path docs/reports/2026-03-16-agent-root-workspace-proof.md --cleanup
```

Expected: PASS, including the repo-root batch scenarios.

**Step 4: Run real `development` repo-root proof**

Before the run, manually remove already-installed proof skills if they would invalidate the scenario.

Then verify in a real conversation flow that:

- `skills_install` with `repo=obra/superpowers` triggers repo-root batch mode
- the batch uses one approval
- discovered skills install atomically
- a later conversation uses at least one installed skill successfully

Write the proof to:

- `docs/reports/2026-03-16-repo-root-skill-batch-proof.md`

**Step 5: Commit**

```bash
git add docs/reports/2026-03-16-agent-root-workspace-proof.md docs/reports/2026-03-16-repo-root-skill-batch-proof.md
git commit -m "test: verify repo-root skill batch installs end to end"
```
