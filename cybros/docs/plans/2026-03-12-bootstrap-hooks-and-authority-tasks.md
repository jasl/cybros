# Bootstrap Hooks And Authority Tasks Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `on_conversation_created` and `on_lane_first_user_message` as append-only bootstrap hooks backed by Cybros-owned authority tasks so welcome messages, bootstrap state, branch-lane summary follow-up, and lane-first-message title generation all remain DAG-visible and Cybros-authoritative.

**Architecture:** Extend the programmable hook contract with a bootstrap-family policy matrix, introduce kernel-owned `cybros_*` authority tools for bootstrap work, and add explicit lifecycle dispatchers at conversation creation, lane attachment, and first-user-message materialization. Keep V1 bootstrap hooks authority-only so no direct callback mutation or agent-program tool routing is needed before a `ConversationRun` exists.

**Tech Stack:** Ruby on Rails, ActiveRecord, DAG graph/lane/node runtime, programmable-agent hook envelope, AgentRPC lifecycle caller, kernel tools registry, existing context-exclusion and conversation mutation APIs

---

### Task 1: Lock The Bootstrap Hook Contract With Red Tests

**Files:**
- Modify: `cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb`
- Modify: `cybros/test/integration/agent_deployments_activation_gate_test.rb`
- Modify: `cybros/agents/default/test/integration/rpc_contract_test.rb`
- Create: `cybros/test/integration/bootstrap_hook_contract_test.rb`

**Step 1: Write the failing test**

Cover:

- `HookEnvelope` accepts `on_conversation_created` and `on_lane_first_user_message`
- those hooks reject `planning`, `set_step_status`, `emit_message`, `halt`, and `deny`
- those hooks accept only `create_task(append)` and only for `cybros_*` logical tool names
- activation/rpc contract tests fail until the bundled/default manifest and deployment requirements expose the new methods

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb cybros/test/integration/bootstrap_hook_contract_test.rb cybros/test/integration/agent_deployments_activation_gate_test.rb cybros/agents/default/test/integration/rpc_contract_test.rb`

Expected: FAIL on missing hook names, missing validation, and bundled/default contract drift.

**Step 3: Write minimal implementation**

Implement only enough contract and manifest scaffolding to express the new hook family and bootstrap-only policy boundary.

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb cybros/test/integration/bootstrap_hook_contract_test.rb cybros/test/integration/agent_deployments_activation_gate_test.rb cybros/agents/default/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/test/lib/cybros/programmable_agent/hook_envelope_test.rb cybros/test/integration/bootstrap_hook_contract_test.rb cybros/test/integration/agent_deployments_activation_gate_test.rb cybros/agents/default/test/integration/rpc_contract_test.rb
git commit -m "test: lock bootstrap hook contract"
```

### Task 2: Add Kernel-Owned Authority Tools For Bootstrap Work

**Files:**
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Create: `cybros/lib/cybros/bootstrap/tools.rb`
- Create: `cybros/test/lib/cybros/bootstrap/tools_test.rb`
- Modify: `cybros/lib/cybros/programmable_agent/kernel_capability_catalog.rb`

**Step 1: Write the failing test**

Cover:

- new kernel tool definitions exist for:
  - `cybros_seed_message`
  - `cybros_bootstrap_state`
  - `cybros_generate_title`
  - `cybros_enqueue_lane_summary`
- those tools appear in the kernel capability catalog
- schema validation rejects malformed payloads
- bootstrap tools never use the agent-program execution path

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/lib/cybros/bootstrap/tools_test.rb`

Expected: FAIL because the bootstrap tools are not registered yet.

**Step 3: Write minimal implementation**

Implement:

- a new kernel tools module for bootstrap authority tasks
- registry wiring so the tools are part of the normal kernel capability catalog
- minimal payload validation and no-op-safe task behavior where full product behavior is not implemented yet

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/lib/cybros/bootstrap/tools_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/cybros/agent_runtime_resolver.rb cybros/lib/cybros/bootstrap/tools.rb cybros/test/lib/cybros/bootstrap/tools_test.rb cybros/lib/cybros/programmable_agent/kernel_capability_catalog.rb
git commit -m "feat: add bootstrap authority tools"
```

### Task 3: Build Lifecycle Dispatchers For Conversation, Lane, And First-User Events

**Files:**
- Create: `cybros/app/services/conversations/bootstrap_hook_dispatcher.rb`
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/app/models/conversation.rb`
- Create: `cybros/test/integration/conversation_bootstrap_dispatch_test.rb`
- Create: `cybros/test/integration/branch_lane_bootstrap_dispatch_test.rb`

**Step 1: Write the failing test**

Cover:

- creating a root conversation fires `on_conversation_created`
- creating a branch conversation fires both hooks for the child conversation / attached branch lane
- repeated reloads do not replay bootstrap dispatch
- the dispatcher runs only after conversation and lane persistence are stable

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/integration/conversation_bootstrap_dispatch_test.rb cybros/test/integration/branch_lane_bootstrap_dispatch_test.rb`

Expected: FAIL because no lifecycle dispatcher exists yet.

**Step 3: Write minimal implementation**

Implement:

- a single service that opens bootstrap hook invocations with the correct `scope_type`, request payload, and idempotent invocation ids
- controller/model wiring that calls the dispatcher after root conversation creation and after branch lane attachment
- stable lifecycle metadata so replay and audit are deterministic

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/integration/conversation_bootstrap_dispatch_test.rb cybros/test/integration/branch_lane_bootstrap_dispatch_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/app/services/conversations/bootstrap_hook_dispatcher.rb cybros/app/controllers/conversations_controller.rb cybros/app/models/conversation.rb cybros/test/integration/conversation_bootstrap_dispatch_test.rb cybros/test/integration/branch_lane_bootstrap_dispatch_test.rb
git commit -m "feat: dispatch bootstrap lifecycle hooks"
```

### Task 4: Teach Hook Action Execution To Materialize Bootstrap Tasks Without A Run Placeholder

**Files:**
- Modify: `cybros/lib/cybros/programmable_agent/hook_action_executor.rb`
- Modify: `cybros/lib/cybros/programmable_agent/hook_envelope.rb`
- Create: `cybros/test/lib/cybros/programmable_agent/bootstrap_hook_action_executor_test.rb`
- Modify: `cybros/test/integration/programmable_agent_hooks_test.rb`

**Step 1: Write the failing test**

Cover:

- bootstrap hooks can append the first task on an empty main lane
- bootstrap hooks do not require an active assistant placeholder
- bootstrap hooks reject non-`cybros_*` logical tool names
- ordinary runtime hooks keep their current validated tool-surface / conversation-run routing behavior

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/lib/cybros/programmable_agent/bootstrap_hook_action_executor_test.rb cybros/test/integration/programmable_agent_hooks_test.rb`

Expected: FAIL because the current executor requires a placeholder node and a bound `ConversationRun` for hook-created tasks.

**Step 3: Write minimal implementation**

Implement:

- a bootstrap-only append path that can create the first node on a lane
- a routing rule that resolves only reserved `cybros_*` tasks through the kernel registry
- separation between bootstrap authority-task routing and existing runtime hook-created task routing

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/lib/cybros/programmable_agent/bootstrap_hook_action_executor_test.rb cybros/test/integration/programmable_agent_hooks_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/cybros/programmable_agent/hook_action_executor.rb cybros/lib/cybros/programmable_agent/hook_envelope.rb cybros/test/lib/cybros/programmable_agent/bootstrap_hook_action_executor_test.rb cybros/test/integration/programmable_agent_hooks_test.rb
git commit -m "feat: materialize bootstrap authority tasks"
```

### Task 5: Implement Bootstrap Authority Task Behavior

**Files:**
- Modify: `cybros/lib/cybros/bootstrap/tools.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/dag/node.rb`
- Create: `cybros/test/integration/bootstrap_seed_message_test.rb`
- Create: `cybros/test/integration/bootstrap_state_task_test.rb`
- Create: `cybros/test/integration/first_user_message_title_task_test.rb`

**Step 1: Write the failing test**

Cover:

- `cybros_seed_message` creates a visible welcome/self-introduction message on the main lane
- the seeded message can be excluded from future prompt context
- `cybros_bootstrap_state` applies conversation settings, agent config, lane kv, and prompt-buffer mutations through task execution
- `on_lane_first_user_message` schedules `cybros_generate_title` on main lanes and branch lanes
- `on_lane_first_user_message` also schedules `cybros_enqueue_lane_summary` on branch lanes
- title generation does not block or corrupt the first assistant reply path

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/test/integration/bootstrap_seed_message_test.rb cybros/test/integration/bootstrap_state_task_test.rb cybros/test/integration/first_user_message_title_task_test.rb`

Expected: FAIL because the authority tools do not yet apply real product behavior.

**Step 3: Write minimal implementation**

Implement:

- assistant-visible seeded message materialization
- optional immediate context exclusion for seeded messages
- atomic bootstrap-state mutation application
- a first-pass title-generation strategy that is Cybros-owned and replay-safe

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/test/integration/bootstrap_seed_message_test.rb cybros/test/integration/bootstrap_state_task_test.rb cybros/test/integration/first_user_message_title_task_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/lib/cybros/bootstrap/tools.rb cybros/app/models/conversation.rb cybros/app/models/dag/node.rb cybros/test/integration/bootstrap_seed_message_test.rb cybros/test/integration/bootstrap_state_task_test.rb cybros/test/integration/first_user_message_title_task_test.rb
git commit -m "feat: execute bootstrap authority tasks"
```

### Task 6: Align Default Agent And Public API Docs

**Files:**
- Modify: `cybros/agents/default/agent.yml`
- Modify: `cybros/agents/default/lib/cybros/agents/default/application.rb`
- Modify: `cybros/agents/default/lib/cybros/agents/default/hooks/`
- Modify: `cybros/docs/product/agent_rpc.md`
- Modify: `cybros/docs/product/kernel_service_surface.md`
- Modify: `cybros/docs/product/programmable_agents.md`
- Modify: `cybros/docs/plans/2026-03-12-bootstrap-hooks-and-authority-tasks-design.md`

**Step 1: Write the failing doc/contract checklist**

Cover:

- bundled/default supports the new bootstrap hook names
- active product docs document:
  - `on_conversation_created`
  - `on_lane_first_user_message`
  - `tool.execute`
  - `tool_surface.manifest`
- active docs stop claiming raw JSON Schema artifacts already exist in-repo as the shipped source of truth
- authority-task boundary is documented clearly

**Step 2: Run test to verify it fails**

Run: `bin/rails test cybros/agents/default/test/integration/rpc_contract_test.rb`

Expected: FAIL until the bundled/default manifest is updated.

**Step 3: Write minimal implementation**

Implement:

- default-agent hook stubs or conservative bootstrap behavior
- public doc updates for the shipped API surface and authority-task boundary
- a correction to the current schema/source-of-truth wording in `agent_rpc.md`

**Step 4: Run test to verify it passes**

Run: `bin/rails test cybros/agents/default/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/agents/default/agent.yml cybros/agents/default/lib/cybros/agents/default/application.rb cybros/agents/default/lib/cybros/agents/default/hooks cybros/docs/product/agent_rpc.md cybros/docs/product/kernel_service_surface.md cybros/docs/product/programmable_agents.md cybros/docs/plans/2026-03-12-bootstrap-hooks-and-authority-tasks-design.md
git commit -m "docs: align bootstrap hooks and public api"
```

### Task 7: Add End-To-End Coverage For The New Bootstrap Path

**Files:**
- Create: `cybros/test/e2e/bootstrap_welcome_message.spec.ts`
- Create: `cybros/test/e2e/first_user_message_title.spec.ts`
- Modify: `cybros/test/e2e/helpers.ts`

**Step 1: Write the failing test**

Cover:

- creating a fresh conversation can show a seeded welcome/self-introduction message
- that seeded message does not pollute later prompt context behavior
- the first real user message eventually updates the conversation title
- branch or lane creation still routes through the right lifecycle path without double-seeding

**Step 2: Run test to verify it fails**

Run: `bunx playwright test cybros/test/e2e/bootstrap_welcome_message.spec.ts cybros/test/e2e/first_user_message_title.spec.ts`

Expected: FAIL because the bootstrap lifecycle does not yet exist in the product path.

**Step 3: Write minimal implementation**

Implement only the small helper or fixture changes needed for stable E2E verification.

**Step 4: Run test to verify it passes**

Run: `bunx playwright test cybros/test/e2e/bootstrap_welcome_message.spec.ts cybros/test/e2e/first_user_message_title.spec.ts`

Expected: PASS

**Step 5: Commit**

```bash
git add cybros/test/e2e/bootstrap_welcome_message.spec.ts cybros/test/e2e/first_user_message_title.spec.ts cybros/test/e2e/helpers.ts
git commit -m "test: cover bootstrap lifecycle flows"
```
