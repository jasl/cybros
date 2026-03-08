# Agent Deployment Connection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebaseline programmable-agent connection, registration, and run materialization around `AgentDeployment`, `RunDraft`, and a real network transport path.

**Architecture:** `ConversationRun` becomes the immutable execution unit produced from a draft. `AgentDeployment` is the only connectable runtime entity in v1, registered explicitly by the operator. `agent_rpc` stays transport-neutral, but production support targets a network binding first and keeps stdio as a dev/test adapter.

**Tech Stack:** Ruby on Rails, PostgreSQL, JSON Schema, WebSocket, Playwright, Agent RPC

---

### Task 1: Align The Normative Product Docs

**Files:**
- Create: `docs/plans/2026-03-09-agent-deployment-connection-design.md`
- Modify: `docs/product/architecture.md`
- Modify: `docs/product/domain_model.md`
- Modify: `docs/product/execution_model.md`
- Modify: `docs/product/programmable_agents.md`
- Modify: `docs/product/state_taxonomy.md`
- Modify: `docs/product/agent_rpc.md`
- Modify: `docs/product/runtime_governance.md`
- Modify: `docs/product/roadmap.md`
- Modify: `docs/product/migration_alignment.md`
- Modify: `docs/plans/2026-03-08-phase-1-schema-cut-list.md`

**Step 1: Write the failing coherence check**

Run: `rg -n "AgentHost|stdio between|agent_host_id|schema-validated using the agent program's per-conversation config schema" docs/product docs/plans/2026-03-08-phase-1-schema-cut-list.md`
Expected: matches that reflect the outdated assumptions.

**Step 2: Update the product docs**

Document:

- `RunDraft` as the mutable planning layer
- `ConversationRun` as the immutable execution unit
- `AgentDeployment` as the only connectable entity
- operator-managed registration
- opaque `agent_config`
- WebSocket-first transport direction with stdio as an optional adapter

**Step 3: Re-run the coherence check**

Run: `rg -n "AgentHost|stdio between|agent_host_id|schema-validated using the agent program's per-conversation config schema" docs/product docs/plans/2026-03-08-phase-1-schema-cut-list.md`
Expected: no stale normative assumptions remain.

**Step 4: Commit**

```bash
git add docs/product docs/plans/2026-03-09-agent-deployment-connection-design.md docs/plans/2026-03-08-phase-1-schema-cut-list.md
git commit -m "docs: rebaseline agent deployment connection model"
```

### Task 2: Supersede The Old Plan Assumptions

**Files:**
- Modify: `docs/plans/2026-03-08-runtime-rebaseline-design.md`
- Modify: `docs/plans/2026-03-08-runtime-rebaseline.md`
- Modify: `docs/plans/2026-03-08-agent-rpc-design.md`
- Modify: `docs/plans/2026-03-08-agent-rpc.md`

**Step 1: Add the failing review check**

Run: `rg -n "AgentHost|stdio|queue-time snapshot freezing|turn.prepare|Task 4: Implement The Stdio Agent Host Adapter" docs/plans/2026-03-08-runtime-rebaseline*.md docs/plans/2026-03-08-agent-rpc*.md`
Expected: matches that still describe the superseded assumptions.

**Step 2: Add supersession notes and fix the plan headers**

Update the old plan documents so they point to `docs/plans/2026-03-09-agent-deployment-connection-design.md` and this plan for:

- deployment registration
- transport binding
- draft vs immutable run semantics

**Step 3: Re-run the review check**

Run: `rg -n "superseded by|2026-03-09-agent-deployment-connection" docs/plans/2026-03-08-runtime-rebaseline*.md docs/plans/2026-03-08-agent-rpc*.md`
Expected: all affected plan files explicitly redirect readers.

**Step 4: Commit**

```bash
git add docs/plans/2026-03-08-runtime-rebaseline-design.md docs/plans/2026-03-08-runtime-rebaseline.md docs/plans/2026-03-08-agent-rpc-design.md docs/plans/2026-03-08-agent-rpc.md
git commit -m "docs: supersede old deployment and transport assumptions"
```

### Task 3: Plan The Domain And Schema Refactor

**Files:**
- Modify: `docs/plans/2026-03-09-agent-deployment-connection.md`
- Reference: `docs/plans/2026-03-08-phase-1-schema-cut-list.md`

**Step 1: Write the explicit schema targets into this plan**

Specify:

- `agent_deployments` fields for transport, endpoint, auth, revision or fingerprint, inspection snapshots, and health
- no `agent_hosts` table in v1
- `conversation_runs` snapshot fields for deployment fingerprint and effective agent config
- `automations` binding to `agent_program_id + execution_target_id`

**Step 2: Add verification commands for the future schema work**

Run targets to name in the later execution plan:

- `bin/rails test test/models/agent_deployment_test.rb`
- `bin/rails test test/models/conversation_run_test.rb`
- `bin/rails test test/models/automation_test.rb test/models/automation_run_test.rb`

**Step 3: Commit**

```bash
git add docs/plans/2026-03-09-agent-deployment-connection.md
git commit -m "docs: plan deployment registration schema refactor"
```

### Task 4: Plan The Real Transport And E2E Flow

**Files:**
- Modify: `docs/plans/2026-03-09-agent-deployment-connection.md`
- Future files to call out explicitly:
  - `protocol/agent_rpc/v1/**`
  - `app/services/agent_rpc/**`
  - `app/models/agent_deployment.rb`
  - `test/integration/agent_deployments_test.rb`
  - `test/e2e/agent_deployment_registration_and_run.spec.ts`

**Step 1: Define the required acceptance scenario**

The E2E path must cover:

1. start a reachable deployment fixture
2. register deployment connection info in Cybros
3. run inspection and healthcheck
4. select the agent in a real conversation flow
5. materialize immutable `ConversationRun` from a draft
6. show deployment facts in the run audit

**Step 2: Add exact verification commands**

Run targets to name in the later execution plan:

- `bin/rails test test/integration/agent_deployments_test.rb`
- `bin/rails test test/integration/programmable_agent_turns_test.rb`
- `bin/e2e test/e2e/agent_deployment_registration_and_run.spec.ts`

**Step 3: Commit**

```bash
git add docs/plans/2026-03-09-agent-deployment-connection.md
git commit -m "docs: plan deployment registration e2e coverage"
```
