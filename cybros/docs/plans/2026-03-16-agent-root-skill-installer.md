# Agent-Root Skill Installer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a protected, byte-preserving skill installation path for agent-root workspaces so bundled `claw` can discover catalog skills and install them into `<agent-root>/skills/` without routing file contents through LLM-authored `write` calls.

**Architecture:** The implementation adds one read-only discovery surface and one protected installer surface. The runtime continues to merge only platform/system skills with agent-local installed skills, while a separate catalog layer exists only for discovery and source resolution. The installer stages remote content, validates the skill package, computes hashes, drives the existing approval path, snapshots the replaced agent-local directory when needed, atomically promotes the staged directory into the live agent root, records provenance, and marks the agent skill inventory dirty for next-top-level-turn refresh.

**Tech Stack:** Ruby on Rails, Pathname/FileUtils, zip/git staging helpers, agent-owned tool registry, protected-path policy, skills store builder, bundled `claw`, Rails tests, real-model live acceptance harness

**Execution Root:** `/Users/jasl/Workspaces/Cybros/cybros/cybros`

**Design Source:** `cybros/docs/plans/2026-03-16-agent-root-skill-installer-design.md`

**Execution Assumptions:**
- this is an intentionally breaking follow-up on top of the approved agent-root workspace cutover
- do not introduce compatibility shims that preserve model-authored remote skill installation
- keep platform/system skills and agent-local installed skills as separate ownership layers
- keep approval-driven live acceptance intact; do not bypass protected writes to make tests easier

---

### Task 1: Lock The Layering And Installer Contract With Failing Tests

**Files:**
- Create: `cybros/app/services/agents/skill_catalog.rb`
- Create: `cybros/app/services/agents/skill_installation_service.rb`
- Create: `cybros/test/services/agents/skill_installation_service_test.rb`
- Create: `cybros/test/services/agents/skill_catalog_test.rb`
- Modify: `cybros/test/services/agents/skills_store_builder_test.rb`
- Modify: `cybros/test/lib/cybros/agent_owned_tools_test.rb`

**Step 1: Write the failing test**

Cover:

- platform/system skills and agent-local installed skills are the only runtime layers
- catalog entries are discoverable but not merged into `skills_store`
- installs that collide with a platform/system skill fail closed
- public tool surface exposes `skills_catalog_list` and `skills_install`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb test/services/agents/skill_catalog_test.rb test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_owned_tools_test.rb`

Expected: FAIL because no catalog service or protected installer tool exists and the public tool surface does not expose the new contract.

**Step 3: Write minimal implementation**

Add only enough scaffolding and failing service stubs to express the contract. Do not fetch remote content yet.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb test/services/agents/skill_catalog_test.rb test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_owned_tools_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add test/services/agents/skill_installation_service_test.rb test/services/agents/skill_catalog_test.rb test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_owned_tools_test.rb
git commit -m "test: lock protected skill installer contract"
```

### Task 2: Add Catalog Discovery Without Changing Runtime Skill Precedence

**Files:**
- Modify: `cybros/app/services/agents/skill_catalog.rb`
- Modify: `cybros/app/models/runtime_setting.rb`
- Modify: `cybros/lib/cybros/agent_owned_tools.rb`
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/test/services/agents/skill_catalog_test.rb`
- Modify: `cybros/test/lib/cybros/agent_owned_tools_test.rb`

**Step 1: Write the failing test**

Cover:

- configured catalog sources resolve deterministically
- `skills_catalog_list` returns entries with installed annotations for the current agent
- runtime skill precedence still merges only platform/system plus agent-local installed skills

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/skill_catalog_test.rb test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_owned_tools_test.rb`

Expected: FAIL because there is no catalog abstraction or discovery tool.

**Step 3: Write minimal implementation**

Implement:

- configured catalog source resolution
- instance-owned catalog configuration under operator/runtime control
- a read-only catalog listing service
- the `skills_catalog_list` public tool schema
- no runtime merge of catalog entries into `skills_store`

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/skill_catalog_test.rb test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_owned_tools_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/skill_catalog.rb app/models/runtime_setting.rb lib/cybros/agent_owned_tools.rb lib/cybros/agent_runtime_resolver.rb test/services/agents/skill_catalog_test.rb test/lib/cybros/agent_owned_tools_test.rb test/services/agents/skills_store_builder_test.rb
git commit -m "feat: add skill catalog discovery surface"
```

### Task 3: Build The Byte-Preserving Staging Pipeline

**Files:**
- Modify: `cybros/app/services/agents/skill_installation_service.rb`
- Create: `cybros/app/services/agents/skill_installation/source_fetcher.rb`
- Create: `cybros/app/services/agents/skill_installation/manifest.rb`
- Modify: `cybros/test/services/agents/skill_installation_service_test.rb`

**Step 1: Write the failing test**

Cover:

- public GitHub source fetch stages a skill directory without touching the live agent root
- staged manifest includes deterministic file list, per-file hashes, and canonical package sha256
- invalid skill roots, traversal attempts, and hash mismatches fail closed before approval
- existing destinations fail closed unless `replace=true`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb`

Expected: FAIL because there is no staging pipeline or validation service.

**Step 3: Write minimal implementation**

Implement:

- GitHub zip fetch with git sparse checkout fallback
- staged skill root resolution
- regular-file-only manifest generation
- canonical package hash generation from the staged manifest
- validation for `SKILL.md`, path traversal, invalid names, existing destinations, and optional `expected_sha256`

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/skill_installation_service.rb app/services/agents/skill_installation/source_fetcher.rb app/services/agents/skill_installation/manifest.rb test/services/agents/skill_installation_service_test.rb
git commit -m "feat: stage and validate remote skills"
```

### Task 4: Add Protected `skills_install` Tool Routing And Policy Enforcement

**Files:**
- Modify: `cybros/lib/cybros/agent_owned_tools.rb`
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/application.rb`
- Create: `cybros/agents/claw/lib/cybros/agents/claw/tools/skill_tools.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`
- Modify: `cybros/test/integration/programmable_agent_tool_routing_test.rb`
- Modify: `cybros/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Cover:

- `skills_install` is exposed to bundled `claw`
- `skills_catalog_list` and `skills_install` both execute through real `claw` implementations
- `skills_install` always requires confirmation
- direct `exec` mutation of protected skill paths is still denied
- platform-skill name collisions fail before approval

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_tool_routing_test.rb`
Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because the tool surface and policy layer do not know about `skills_install`.

**Step 3: Write minimal implementation**

Implement:

- `skills_install` tool schema on the public surface
- `skills_catalog_list` tool schema on the public surface
- runtime routing from the tool call to the installation service
- concrete `claw` skill-tool execution plumbing through `tool_executor`
- protected-path policy treatment that always confirms installer mutations
- stable early failure when `install_as` collides with a platform/system skill or an existing destination is targeted without `replace=true`

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_tool_routing_test.rb`
Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add lib/cybros/agent_owned_tools.rb lib/cybros/agent_runtime_resolver.rb agents/claw/lib/cybros/agents/claw/application.rb agents/claw/lib/cybros/agents/claw/tools/skill_tools.rb agents/claw/lib/cybros/agents/claw/tool_executor.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_tool_routing_test.rb agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: route protected skill installs through runtime tools"
```

### Task 5: Snapshot, Atomic Promote, And Provenance

**Files:**
- Create: `cybros/app/services/agents/skill_installation/provenance_store.rb`
- Modify: `cybros/app/services/agents/skill_installation_service.rb`
- Modify: `cybros/test/services/agents/skill_installation_service_test.rb`
- Modify: `cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`

**Step 1: Write the failing test**

Cover:

- replacing an existing agent-local skill snapshots the previous live directory into `.history/skills/**`
- new installs do not create empty snapshots
- provenance metadata is written outside the agent-writable skill tree
- install failures do not leave partially promoted live files
- generic fetched-text `write` paths are not treated as successful remote installation

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: FAIL because snapshot and promote semantics do not exist for installer-managed skill directories.

**Step 3: Write minimal implementation**

Implement:

- runtime-managed directory snapshotting for replaced agent-local skills
- atomic staging-to-live promotion
- provenance metadata write
- explicit cleanup on promote failure

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/skill_installation/provenance_store.rb app/services/agents/skill_installation_service.rb test/services/agents/skill_installation_service_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb
git commit -m "feat: snapshot and promote installed skills atomically"
```

### Task 6: Refresh Installed Skills On The Next Top-Level Turn

**Files:**
- Modify: `cybros/app/services/agents/skills_store_builder.rb`
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/test/services/agents/skills_store_builder_test.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

**Step 1: Write the failing test**

Cover:

- successful installs mark the agent skill inventory dirty
- the current turn does not see the newly installed skill mid-turn
- the next top-level turn does see the new skill
- the refreshed store still fails closed on platform/system collisions

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

Expected: FAIL because the runtime does not yet distinguish installer-triggered refresh from ordinary skill-store snapshots.

**Step 3: Write minimal implementation**

Implement:

- skill inventory dirty marker
- next-top-level-turn rebuild of the merged store
- stable collision handling on refreshed state

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/skills_store_builder.rb lib/cybros/agent_runtime_resolver.rb test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb
git commit -m "feat: refresh installed skills on next top-level turn"
```

### Task 7: Teach The Agent To Prefer The Installer Workflow

**Files:**
- Create: `cybros/skills/.system/skill-installer/SKILL.md`
- Modify: `cybros/app/services/agents/skills_store_builder.rb`
- Modify: `cybros/test/integration/programmable_agent_prompt_builder_test.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

**Step 1: Write the failing test**

Cover:

- the runtime exposes a system `skill-installer` skill in the available-skills inventory
- the skill instructs the agent to use `skills_catalog_list` and `skills_install` instead of model-authored remote file reconstruction
- agent-local installed skills still remain separate from the system layer

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/programmable_agent_prompt_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

Expected: FAIL because no system installer skill exists and no prompt guidance points the model toward the new workflow.

**Step 3: Write minimal implementation**

Implement:

- system `skill-installer` skill content
- platform/system skill root registration
- prompt coverage proving the skill appears in inventory

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/programmable_agent_prompt_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add skills/.system/skill-installer/SKILL.md app/services/agents/skills_store_builder.rb test/integration/programmable_agent_prompt_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb
git commit -m "feat: add system skill installer guidance"
```

### Task 8: Extend Live Acceptance For Protected Skill Installation

**Files:**
- Modify: `cybros/script/live_acceptance/agent_root_workspace.rb`
- Create: `cybros/test/script/live_acceptance/skill_installer_test.rb`
- Modify: `cybros/test/script/live_acceptance/agent_root_workspace_test.rb`

**Step 1: Write the failing test**

Cover:

- catalog listing succeeds in the live harness
- a protected install from a catalog entry through the real approval path succeeds
- a protected install from a direct GitHub repo/path through the real approval path succeeds
- installed hash matches the staged source hash
- next top-level turn sees the installed skill
- a later conversation successfully uses the installed skill
- replacing an installed skill creates a `.history/skills/**` snapshot
- install attempts that collide with a system/platform skill fail through the real path
- direct `exec` mutation attempts against protected skill paths remain denied in live execution

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/script/live_acceptance/skill_installer_test.rb test/script/live_acceptance/agent_root_workspace_test.rb`

Expected: FAIL because the live harness does not know how to drive the new installer scenario set.

**Step 3: Write minimal implementation**

Implement:

- new live acceptance scenario helpers
- approval-driving support for `skills_install`
- live scenarios for both catalog-sourced and direct-GitHub installs
- live scenarios for replacement snapshotting, platform collision rejection, and protected-path exec denial
- proof report fields for source/install hashes and snapshot paths

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/script/live_acceptance/skill_installer_test.rb test/script/live_acceptance/agent_root_workspace_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add script/live_acceptance/agent_root_workspace.rb test/script/live_acceptance/skill_installer_test.rb test/script/live_acceptance/agent_root_workspace_test.rb
git commit -m "test: cover protected skill installs in live acceptance"
```

### Task 9: Run Full Verification And Real-Model Acceptance

**Files:**
- Verify only

**Step 1: Run targeted deterministic verification**

Run: `bin/rails test test/services/agents/skill_installation_service_test.rb test/services/agents/skill_catalog_test.rb test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_owned_tools_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_tool_routing_test.rb test/integration/programmable_agent_prompt_builder_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb test/script/live_acceptance/skill_installer_test.rb test/script/live_acceptance/agent_root_workspace_test.rb`

Expected: PASS

**Step 2: Run bundled `claw` contract verification**

Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 3: Run real-model live acceptance**

Run: `bin/rails runner script/live_acceptance/agent_root_workspace.rb --model-ref openrouter/openai-gpt-5.4 --runs 3 --report-path docs/reports/2026-03-16-agent-root-workspace-proof.md --cleanup`

Expected: PASS with protected installer scenarios going through the shipped approval path.

**Step 4: Review output before claiming completion**

Confirm:

- protected installer scenarios passed
- installed hashes and source hashes match
- replacement scenarios emitted `.history/skills/**` snapshots
- no scenario bypassed approval

**Step 5: Commit**

```bash
git add docs/reports/2026-03-16-agent-root-workspace-proof.md
git commit -m "test: verify protected skill installer end to end"
```
