# Agent Root Workspace Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace conversation-owned logical workspaces and lane-kv memory with an agent-root workspace, three-scope file-backed memory, bundled bootstrap/skill seeding, and agent-local mutable skills for bundled `claw`.

**Architecture:** The cutover keeps Cybros as the owner of DAG execution, approvals, transcript durability, and branch semantics, but moves workspace and memory truth into an agent-owned filesystem root. Each `Agent` gets one root workspace, each `Conversation` gets a lightweight working directory beneath it, and each lane gets an optional hidden `.lanes/<lane_id>` directory only when lane-local state is needed. Memory tools become the controlled API over file-backed `MEMORY.md` and `memory/YYYY-MM-DD.md` files at root, conversation, and lane scope. Bundled `claw` also seeds a live `skills/` tree into that root, merges agent-local skills with platform skills at runtime, and uses an agent-local `self-mutate` skill plus normal file tools to mutate `SOUL.md`, `USER.md`, and `skills/**` under strict confirmation and `.history/` snapshot rules.

**Tech Stack:** Ruby on Rails, ActiveRecord, PostgreSQL, Pathname/FileUtils, bundled `claw` agent host, programmable-agent hooks, DAG lanes/branching, Rails integration tests, real-model acceptance harness

**Execution Root:** `/Users/jasl/Workspaces/Cybros/cybros/cybros`

**Design Source:** `cybros/docs/plans/2026-03-16-agent-root-workspace-design.md`

---

### Task 1: Lock The Cutover Contract With Failing Tests

**Files:**
- Create: `cybros/test/services/agents/workspace_initializer_test.rb`
- Modify: `cybros/test/services/conversations/workspace_initializer_test.rb`
- Modify: `cybros/test/services/agent_rpc/kernel_services/conversation_memory_test.rb`
- Modify: `cybros/test/integration/conversation_branching_test.rb`

**Step 1: Write the failing test**

Cover:

- one `Agent` root workspace path is shared by many conversations
- `Conversation` resolves to `conversations/<conversation_id>/`
- lane paths resolve to `conversations/<conversation_id>/.lanes/<lane_id>/`
- conversation and lane directories are lazy
- branch copies parent conversation `MEMORY.md` but not `.lanes/`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/workspace_initializer_test.rb test/services/conversations/workspace_initializer_test.rb test/services/agent_rpc/kernel_services/conversation_memory_test.rb test/integration/conversation_branching_test.rb`

Expected: FAIL because the code still assumes conversation-owned workspace metadata and conversation-backed logical memory.

**Step 3: Write minimal implementation**

Implement only enough scaffolding to express the new path contract and failing branch snapshot expectation. Do not change prompt/bootstrap or memory search semantics yet.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/workspace_initializer_test.rb test/services/conversations/workspace_initializer_test.rb test/services/agent_rpc/kernel_services/conversation_memory_test.rb test/integration/conversation_branching_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add test/services/agents/workspace_initializer_test.rb test/services/conversations/workspace_initializer_test.rb test/services/agent_rpc/kernel_services/conversation_memory_test.rb test/integration/conversation_branching_test.rb
git commit -m "test: lock agent root workspace contract"
```

### Task 2: Move Workspace Ownership From Conversation To Agent

**Files:**
- Create: `cybros/app/services/agents/workspace_path_resolver.rb`
- Create: `cybros/app/services/agents/workspace_initializer.rb`
- Modify: `cybros/app/models/agent.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/runtime_setting.rb`
- Modify: `cybros/app/services/conversations/workspace_initializer.rb`
- Modify: `cybros/db/schema.rb`

**Step 1: Write the failing test**

Add assertions that:

- agent root path is derived from `RuntimeSetting.agent_workspace_root`
- bundled `claw` path resolves to `<base>/claw-<agent_id>`
- `Conversation#logical_workspace_*` is no longer the product truth
- conversation/lane path helpers resolve under the agent root

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/workspace_initializer_test.rb test/services/conversations/workspace_initializer_test.rb test/models/agent_test.rb test/models/conversation_program_selection_test.rb`

Expected: FAIL because there is no agent-root path service and conversation still advertises logical workspace ownership.

**Step 3: Write minimal implementation**

Implement:

- agent-root path derivation and materialization services
- conversation and lane path resolution helpers
- removal or demotion of conversation-owned workspace metadata from the runtime path
- a compatibility shim in `Conversations::WorkspaceInitializer` only if needed as a temporary adapter inside this branch

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/workspace_initializer_test.rb test/services/conversations/workspace_initializer_test.rb test/models/agent_test.rb test/models/conversation_program_selection_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/workspace_path_resolver.rb app/services/agents/workspace_initializer.rb app/models/agent.rb app/models/conversation.rb app/models/runtime_setting.rb app/services/conversations/workspace_initializer.rb db/schema.rb test/services/agents/workspace_initializer_test.rb test/services/conversations/workspace_initializer_test.rb test/models/agent_test.rb test/models/conversation_program_selection_test.rb
git commit -m "feat: move workspace ownership to agents"
```

### Task 3: Seed Live Agent Roots From Bundled `claw` Prompts And Skills

**Files:**
- Create: `cybros/app/services/agents/workspace_bootstrap.rb`
- Modify: `cybros/app/services/agents/bootstrap_bundled_default_service.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/application.rb`
- Modify: `cybros/test/services/agents/bootstrap_bundled_default_service_test.rb`
- Modify: `cybros/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Cover:

- first real agent-root materialization seeds `AGENTS.md`, `SOUL.md`, `USER.md`, and starter memory files
- first real agent-root materialization seeds bundled `skills/*` into the live root when bundled skills exist
- bundled source files are only templates after bootstrap
- `claw` reads live workspace bootstrap files, not just `agents/claw/prompts/*`

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb`
Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because no workspace seeding path exists and `claw` still reads bundled prompt files directly.

**Step 3: Write minimal implementation**

Implement:

- root bootstrap copier
- idempotent seeding rules
- prompt file resolution from the live agent root
- bundled skill seed rules into `<agent-root>/skills`

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/bootstrap_bundled_default_service_test.rb`
Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/workspace_bootstrap.rb app/services/agents/bootstrap_bundled_default_service.rb agents/claw/lib/cybros/agents/claw/application.rb test/services/agents/bootstrap_bundled_default_service_test.rb agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: seed live agent root bootstrap files"
```

### Task 4: Rewire Conversation Working Directories And Attachment Materialization

**Files:**
- Modify: `cybros/app/services/conversations/attachment_transfer_service.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/test/integration/default_agent_attachment_transfer_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/tool_execution_test.rb`
- Modify: `cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`

**Step 1: Write the failing test**

Cover:

- default `cwd` for a conversation is `conversations/<conversation_id>/`
- attachments land under that conversation directory
- ordinary file tools do not default to agent root or hidden lane directories

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/default_agent_attachment_transfer_test.rb test/lib/cybros/programmable_agent/tool_execution_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: FAIL because file materialization and tool execution still assume conversation-owned root paths.

**Step 3: Write minimal implementation**

Implement:

- conversation working-directory resolution under the agent root
- attachment transfer under `conversations/<conversation_id>/attachments`
- updated runtime/session context payloads exposing root/conversation/lane paths separately

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/default_agent_attachment_transfer_test.rb test/lib/cybros/programmable_agent/tool_execution_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/conversations/attachment_transfer_service.rb app/models/conversation.rb test/integration/default_agent_attachment_transfer_test.rb test/lib/cybros/programmable_agent/tool_execution_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb
git commit -m "feat: route conversation files through agent root workspaces"
```

### Task 5: Replace Lane-Kv Memory With File-Backed Scoped Memory

**Files:**
- Create: `cybros/app/services/agent_rpc/kernel_services/workspace_memory.rb`
- Modify: `cybros/app/services/agent_rpc/kernel_services/conversation_memory.rb`
- Modify: `cybros/app/services/agent_rpc/callback_dispatcher.rb`
- Modify: `cybros/test/services/agent_rpc/kernel_services/conversation_memory_test.rb`
- Create: `cybros/test/services/agent_rpc/kernel_services/workspace_memory_test.rb`

**Step 1: Write the failing test**

Cover:

- `MEMORY.md` and `memory/YYYY-MM-DD.md` are filesystem truth
- root, conversation, and lane scopes resolve to distinct file roots
- first write lazily materializes missing files/directories
- empty scopes return stable not-materialized results

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agent_rpc/kernel_services/conversation_memory_test.rb test/services/agent_rpc/kernel_services/workspace_memory_test.rb`

Expected: FAIL because memory is still backed by lane kv and callback methods only understand conversation-scoped logical documents.

**Step 3: Write minimal implementation**

Implement:

- file-backed memory storage service
- scope-aware path resolution
- adapter behavior in the old `ConversationMemory` entry points only if needed during the cutover

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agent_rpc/kernel_services/conversation_memory_test.rb test/services/agent_rpc/kernel_services/workspace_memory_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agent_rpc/kernel_services/workspace_memory.rb app/services/agent_rpc/kernel_services/conversation_memory.rb app/services/agent_rpc/callback_dispatcher.rb test/services/agent_rpc/kernel_services/conversation_memory_test.rb test/services/agent_rpc/kernel_services/workspace_memory_test.rb
git commit -m "feat: store scoped memory in workspace files"
```

### Task 6: Add Scoped `memory_*` Tool Semantics And Stable Errors

**Files:**
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/tool_executor.rb`
- Modify: `cybros/agents/claw/test/integration/rpc_contract_test.rb`
- Modify: `cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`

**Step 1: Write the failing test**

Cover:

- `memory_search` searches `lane -> conversation -> root`
- results include `scope`, `path`, `line`, and `snippet`
- `memory_get` has deterministic default targets per scope
- `memory_store` defaults to `scope=lane`
- invalid scopes return a stable domain error

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`
Run: `bin/rails test test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: FAIL because current memory tools do not expose scope semantics or stable scope-aware errors.

**Step 3: Write minimal implementation**

Implement:

- scope-aware tool arguments
- deterministic search ordering
- stable domain errors such as `claw.memory.invalid_scope`
- lazy file materialization through the scoped memory service

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`
Run: `bin/rails test test/scenarios/dag/agent_tool_calls_flow_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb agents/claw/lib/cybros/agents/claw/tool_executor.rb agents/claw/test/integration/rpc_contract_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb
git commit -m "feat: add scoped claw memory tools"
```

### Task 7: Implement Promotion Windows And Branch Memory Snapshot

**Files:**
- Create: `cybros/app/services/conversations/lane_memory_promotion_service.rb`
- Create: `cybros/app/services/conversations/branch_memory_snapshot.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/test/integration/conversation_branching_test.rb`
- Modify: `cybros/test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`

**Step 1: Write the failing test**

Cover:

- compaction/context-pressure path offers a lane -> conversation promotion window
- branching from a live lane promotes durable lane conclusions before snapshot when needed
- child conversation copies parent conversation `MEMORY.md`
- there is no automatic conversation -> root promotion

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/conversation_branching_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`

Expected: FAIL because current compaction and branching flows do not know about scoped file-backed memory or promotion windows.

**Step 3: Write minimal implementation**

Implement:

- lane-promotion orchestration at approved lifecycle points only
- branch snapshot copy of conversation memory
- explicit guard that conversation->root promotion stays non-automatic

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/conversation_branching_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/conversations/lane_memory_promotion_service.rb app/services/conversations/branch_memory_snapshot.rb agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb app/models/conversation.rb test/integration/conversation_branching_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb
git commit -m "feat: add memory promotion windows and branch snapshots"
```

### Task 8: Rebuild Prompt Bootstrap Around Live Root Files, Scope Inventory, And Skills

**Files:**
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`
- Modify: `cybros/agents/claw/lib/cybros/agents/claw/application.rb`
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/test/integration/programmable_agent_prompt_builder_test.rb`
- Modify: `cybros/agents/claw/test/integration/rpc_contract_test.rb`

**Step 1: Write the failing test**

Cover:

- main prompt injects root bootstrap from the live agent root
- prompt includes root/conversation/lane scope inventory
- prompt exposes merged available-skills inventory from platform and agent-local skills
- full conversation/lane memory bodies are not auto-injected
- delegated prompt mode stays minimal

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/programmable_agent_prompt_builder_test.rb`
Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Expected: FAIL because prompt assembly still assumes bundled prompt files plus a conversation-backed memory document.

**Step 3: Write minimal implementation**

Implement:

- live-root bootstrap reads
- scope inventory rendering
- merged platform + agent-local skills resolution
- conservative memory injection rules
- prompt budget updates for the new bootstrap shape

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/programmable_agent_prompt_builder_test.rb`
Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb agents/claw/lib/cybros/agents/claw/application.rb lib/cybros/agent_runtime_resolver.rb test/integration/programmable_agent_prompt_builder_test.rb agents/claw/test/integration/rpc_contract_test.rb
git commit -m "feat: bootstrap claw prompts and skills from live agent roots"
```

### Task 9: Add Agent-Local Skills Discovery And Conflict Rules

**Files:**
- Create: `cybros/app/services/agents/skills_store_builder.rb`
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`
- Create: `cybros/test/services/agents/skills_store_builder_test.rb`
- Modify: `cybros/test/integration/programmable_agent_prompt_builder_test.rb`

**Step 1: Write the failing test**

Cover:

- runtime registers agent-local skills from `<agent-root>/skills`
- platform skills and agent-local skills are both visible to the prompt/runtime
- name collisions between platform and agent-local skills fail closed
- agent-local skills are not loaded from bundled source after bootstrap when live copies exist

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_prompt_builder_test.rb`

Expected: FAIL because the runtime only registers platform-level skills and has no agent-root skills merge layer or collision handling.

**Step 3: Write minimal implementation**

Implement:

- agent-root skills store builder
- merged runtime skills store registration
- fail-closed collision detection

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/agents/skills_store_builder_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/integration/programmable_agent_prompt_builder_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add app/services/agents/skills_store_builder.rb lib/cybros/agent_runtime_resolver.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/services/agents/skills_store_builder_test.rb test/integration/programmable_agent_prompt_builder_test.rb
git commit -m "feat: add agent-local skills discovery"
```

### Task 10: Seed The `self-mutate` Skill And Protected Write Boundaries

**Files:**
- Create: `cybros/agents/claw/skills/self-mutate/SKILL.md`
- Modify: `cybros/app/services/agents/workspace_bootstrap.rb`
- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/test/scenarios/dag/agent_tool_calls_flow_test.rb`
- Modify: `cybros/test/integration/bundled_default_agent_execution_test.rb`
- Modify: `cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

**Step 1: Write the failing test**

Cover:

- bundled `claw` seeds a live `self-mutate` skill into `<agent-root>/skills/self-mutate/`
- writes to `SOUL.md`, `USER.md`, and `skills/**` always require confirmation
- attempts to mutate `AGENTS.md` through normal file tools are denied by the protected-path policy
- the `self-mutate` skill instructs the agent to diff, confirm, snapshot to `.history/`, and then write

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb test/integration/bundled_default_agent_execution_test.rb`

Expected: FAIL because there is no seeded self-mutate skill and no protected write boundary for mutable bootstrap or skill paths.

**Step 3: Write minimal implementation**

Implement:

- bundled `self-mutate` skill seed
- protected write-path policy for `SOUL.md`, `USER.md`, and `skills/**`
- explicit deny for `AGENTS.md` mutation in the agent-owned mutable layer
- `.history/` snapshot path conventions for mutable bootstrap and skill files

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb test/integration/bundled_default_agent_execution_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
git add agents/claw/skills/self-mutate/SKILL.md app/services/agents/workspace_bootstrap.rb lib/cybros/agent_runtime_resolver.rb test/scenarios/dag/agent_tool_calls_flow_test.rb test/integration/bundled_default_agent_execution_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb
git commit -m "feat: add claw self-mutate skill and protected writes"
```

### Task 11: Add Real-LLM Acceptance Harness, Proof, And Final Cleanup

**Files:**
- Create: `cybros/script/live_acceptance/agent_root_workspace.rb`
- Create: `cybros/docs/reports/2026-03-16-agent-root-workspace-proof.md`
- Modify: `cybros/docs/product/README.md`
- Modify: `cybros/test/integration/bundled_default_agent_execution_test.rb`
- Modify: `cybros/test/integration/bundled_agent_parity_test.rb`

**Step 1: Write the failing test**

Cover:

- proof harness enumerates the six required live scenarios from the design
- product docs stop claiming each conversation owns one persistent logical workspace
- bundled default execution paths expose the new root/conversation/lane semantics

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/bundled_default_agent_execution_test.rb test/integration/bundled_agent_parity_test.rb`

Expected: FAIL because docs/tests still encode conversation-owned workspace semantics and there is no live-acceptance harness.

**Step 3: Write minimal implementation**

Implement:

- a real-model acceptance runner that exercises:
  1. root shared memory
  2. conversation isolation
  3. lane-local memory isolation
  4. branch snapshot inheritance
  5. directory-complexity tolerance
  6. compaction durability
  7. self-mutate `SOUL.md`
  8. self-mutate `USER.md`
  9. create a new agent-local skill
  10. modify an existing agent-local skill
  11. fail closed on `AGENTS.md` mutation
- a proof report template that records exact dates, model, environment, and outcomes
- final doc cleanup for the new ownership model

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/integration/bundled_default_agent_execution_test.rb test/integration/bundled_agent_parity_test.rb`
Run: `bin/rails runner script/live_acceptance/agent_root_workspace.rb`

Expected: PASS for the deterministic tests, then a successful live-acceptance run with all eleven scenarios green and no mid-run manual rescue.

**Step 5: Commit**

```bash
git add script/live_acceptance/agent_root_workspace.rb docs/reports/2026-03-16-agent-root-workspace-proof.md docs/product/README.md test/integration/bundled_default_agent_execution_test.rb test/integration/bundled_agent_parity_test.rb
git commit -m "test: prove agent root workspace and self-mutate flow"
```

### Final Verification

Run: `bin/rails test test/services/agents/workspace_initializer_test.rb test/services/agents/skills_store_builder_test.rb test/services/conversations/workspace_initializer_test.rb test/services/agent_rpc/kernel_services/conversation_memory_test.rb test/services/agent_rpc/kernel_services/workspace_memory_test.rb test/integration/conversation_branching_test.rb test/integration/programmable_agent_prompt_builder_test.rb test/integration/default_agent_attachment_transfer_test.rb test/integration/bundled_default_agent_execution_test.rb test/integration/bundled_agent_parity_test.rb test/scenarios/dag/agent_tool_calls_flow_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

Run: `bundle exec ruby -Itest agents/claw/test/integration/rpc_contract_test.rb`

Run: `bin/rails runner script/live_acceptance/agent_root_workspace.rb`

Expected:

- all deterministic tests pass
- bundled `claw` RPC contract passes
- live acceptance completes all eleven scenarios successfully without manual prompt rescue

Plan complete and saved to `docs/plans/2026-03-16-agent-root-workspace.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
