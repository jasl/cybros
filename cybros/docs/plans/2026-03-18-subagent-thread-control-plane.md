# Subagent Thread Control Plane Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor Cybros subagents so the child remains a browsable conversation-backed DAG while a new `SubagentThread` model becomes the sole control-plane authority for lifecycle, owner proxy actions, freeze, notifications, and join semantics.

**Architecture:** Add a durable `SubagentThread` model keyed by `subagent_id`, keep child `Conversation` as the transcript/DAG container, route every mutable subagent action through a shared control-plane service, freeze active children when the owner turn finalizes, and make abnormal child terminal states produce parent-visible notices without merging graphs. Strengthen graph-topology tests and require real development proof before acceptance.

**Tech Stack:** Ruby on Rails, ActiveRecord, PostgreSQL, DAG runtime, programmable-agent hooks, Hotwire UI, Minitest, `bin/dev`, development-model live proof

---

## Execution Preconditions

- Before any Rails command, run `pg_isready`.
- If PostgreSQL is not accepting connections, start it using the repository/environment instructions before continuing.
- Treat this cut as destructive. If old data or fixtures block progress, reset the database instead of adding compatibility code.
- Treat graph-structure assertions as first-class acceptance criteria, not optional regression coverage.
- Treat one real `bin/dev` subagent run and a written proof report as mandatory acceptance gates.

### Task 1: Lock The New Control-Plane And Graph-Topology Acceptance Tests

**Files:**
- Create: `cybros/test/models/subagent_thread_test.rb`
- Create: `cybros/test/services/subagent_threads/control_plane_test.rb`
- Create: `cybros/test/services/subagent_threads/owner_finalizer_test.rb`
- Modify: `cybros/test/lib/cybros/subagent/tools_test.rb`
- Modify: `cybros/test/lib/cybros/subagent/run_wait_tools_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/execution_context_test.rb`
- Modify: `cybros/test/integration/programmable_agent_execution_context_test.rb`
- Modify: `cybros/test/lib/agent_core/resources/tools/tool_name_resolver_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/capability_snapshot_test.rb`
- Modify: `cybros/test/models/conversation/turn_execution_subagent_activity_test.rb`
- Modify: `cybros/test/models/conversation_statistics_origin_test.rb`
- Modify: `cybros/test/models/statistics/tool_call_fact_projector_test.rb`
- Modify: `cybros/test/scenarios/dag/programmable_agent_subagent_fanout_test.rb`
- Modify: `cybros/test/scenarios/dag/programmable_agent_subagent_aggregation_test.rb`
- Create: `cybros/test/scenarios/dag/subagent_thread_graph_topology_test.rb`

**Step 1: Write the failing test**

Cover:

- `subagent_id` is backed by a new durable `SubagentThread`
- parent and child remain separate graphs
- no hidden merge edges appear
- normal join uses `subagent_wait`
- abnormal child terminal states create a parent-owned notice/join activity
- owner finalization freezes active child threads and makes the child read-only
- non-owner terminal child states notify the owner
- child programmable execution context is derived from `SubagentThread`, not child metadata
- statistics attribution and turn execution projection stop treating `metadata["subagent"]` as runtime truth
- the full subagent tool family is recognized as kernel-owned for alias resolution and capability snapshots

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/subagent_thread_test.rb test/services/subagent_threads/control_plane_test.rb test/services/subagent_threads/owner_finalizer_test.rb test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/lib/cybros/programmable_agent/execution_context_test.rb test/integration/programmable_agent_execution_context_test.rb test/lib/agent_core/resources/tools/tool_name_resolver_test.rb test/lib/cybros/programmable_agent/capability_snapshot_test.rb test/models/conversation/turn_execution_subagent_activity_test.rb test/models/conversation_statistics_origin_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/scenarios/dag/programmable_agent_subagent_fanout_test.rb test/scenarios/dag/programmable_agent_subagent_aggregation_test.rb test/scenarios/dag/subagent_thread_graph_topology_test.rb`

Expected: FAIL because `SubagentThread` does not exist and the runtime still treats child `Conversation.metadata` as the source of truth.

**Step 3: Land the failing expectations only**

Only add and update tests and fixtures needed to express the new architecture. Do not implement production code in this step.

**Step 4: Run test to verify it still fails for the intended reason**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/subagent_thread_test.rb test/services/subagent_threads/control_plane_test.rb test/services/subagent_threads/owner_finalizer_test.rb test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/lib/cybros/programmable_agent/execution_context_test.rb test/integration/programmable_agent_execution_context_test.rb test/lib/agent_core/resources/tools/tool_name_resolver_test.rb test/lib/cybros/programmable_agent/capability_snapshot_test.rb test/models/conversation/turn_execution_subagent_activity_test.rb test/models/conversation_statistics_origin_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/scenarios/dag/programmable_agent_subagent_fanout_test.rb test/scenarios/dag/programmable_agent_subagent_aggregation_test.rb test/scenarios/dag/subagent_thread_graph_topology_test.rb`

Expected: FAIL because the control-plane model and topology rules are not implemented yet.

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/test/models/subagent_thread_test.rb cybros/test/services/subagent_threads/control_plane_test.rb cybros/test/services/subagent_threads/owner_finalizer_test.rb cybros/test/lib/cybros/subagent/tools_test.rb cybros/test/lib/cybros/subagent/run_wait_tools_test.rb cybros/test/lib/cybros/programmable_agent/execution_context_test.rb cybros/test/integration/programmable_agent_execution_context_test.rb cybros/test/lib/agent_core/resources/tools/tool_name_resolver_test.rb cybros/test/lib/cybros/programmable_agent/capability_snapshot_test.rb cybros/test/models/conversation/turn_execution_subagent_activity_test.rb cybros/test/models/conversation_statistics_origin_test.rb cybros/test/models/statistics/tool_call_fact_projector_test.rb cybros/test/scenarios/dag/programmable_agent_subagent_fanout_test.rb cybros/test/scenarios/dag/programmable_agent_subagent_aggregation_test.rb cybros/test/scenarios/dag/subagent_thread_graph_topology_test.rb
git commit -m "test: lock subagent thread control-plane acceptance"
```

### Task 2: Add The `SubagentThread` Durable Model And Schema

**Files:**
- Create: `cybros/app/models/subagent_thread.rb`
- Create: `cybros/db/migrate/20260318120000_create_subagent_threads.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/conversation_run.rb`
- Modify: `cybros/app/models/turn_internal_task.rb`
- Modify: `cybros/db/schema.rb`
- Modify: `cybros/test/models/subagent_thread_test.rb`

**Step 1: Write the failing test**

Cover:

- `SubagentThread` validates owner and child bindings
- its primary key is the public `subagent_id`
- it stores `status`, `child_status`, `depth`, `terminal_origin`, `freeze_reason`, `last_snapshot`, and `final_snapshot`
- a managed child graph can resolve its owner through `subagent_threads.child_graph_id`
- conversations can reference owned child threads without depending on `metadata["subagent"]`

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/subagent_thread_test.rb`

Expected: FAIL because the table and model do not exist yet.

**Step 3: Write minimal implementation**

Implement:

- `SubagentThread` with explicit owner and child associations
- explicit `child_graph` ownership so a managed child graph can resolve its owner at the database layer
- string-backed enums for `status` and `child_status`
- `depth` and debug-provenance fields needed by child browse pages and execution-context hydration
- helper methods such as `active?`, `frozen?`, `terminal?`, and `read_only?`
- schema indexes for owner turn lookup, child conversation lookup, child graph lookup, and status lookup
- uniqueness on `child_conversation_id` and `child_graph_id`
- restrictive foreign keys so managed child graphs do not silently become ownerless

Do not add compatibility logic for old conversation metadata.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/subagent_thread_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/app/models/subagent_thread.rb cybros/db/migrate/20260318120000_create_subagent_threads.rb cybros/app/models/conversation.rb cybros/app/models/conversation_run.rb cybros/app/models/turn_internal_task.rb cybros/db/schema.rb cybros/test/models/subagent_thread_test.rb
git commit -m "feat: add durable subagent thread model"
```

### Task 3: Introduce A Shared Subagent Control Plane Service

**Files:**
- Create: `cybros/app/services/subagent_threads/control_plane.rb`
- Create: `cybros/app/services/subagent_threads/snapshot_builder.rb`
- Create: `cybros/app/services/subagent_threads/owner_authority.rb`
- Modify: `cybros/lib/cybros/subagent/tools.rb`
- Modify: `cybros/lib/cybros/programmable_agent/execution_context.rb`
- Modify: `cybros/app/services/statistics/tool_call_fact_projector.rb`
- Modify: `cybros/test/services/subagent_threads/control_plane_test.rb`
- Modify: `cybros/test/lib/cybros/subagent/tools_test.rb`
- Modify: `cybros/test/lib/cybros/subagent/run_wait_tools_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/execution_context_test.rb`
- Modify: `cybros/test/integration/programmable_agent_execution_context_test.rb`
- Modify: `cybros/test/models/conversation_statistics_origin_test.rb`
- Modify: `cybros/test/models/statistics/tool_call_fact_projector_test.rb`

**Step 1: Write the failing test**

Cover:

- `subagent_spawn`, `subagent_run`, `subagent_poll`, and `subagent_wait` resolve through `SubagentThread`
- ownership checks use the new model, not `Conversation.metadata`
- snapshots are built from durable control-plane state plus child graph inspection
- child programmable execution context resolves subagent identity and owner links through `SubagentThread`
- statistics execution scope and sample-origin behavior keep working without metadata-driven ownership truth

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/subagent_threads/control_plane_test.rb test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/lib/cybros/programmable_agent/execution_context_test.rb test/integration/programmable_agent_execution_context_test.rb test/models/conversation_statistics_origin_test.rb test/models/statistics/tool_call_fact_projector_test.rb`

Expected: FAIL because the tools still create and load child conversations directly.

**Step 3: Write minimal implementation**

Implement:

- `SubagentThreads::ControlPlane.spawn!`
- `SubagentThreads::ControlPlane.run!`
- `SubagentThreads::ControlPlane.poll!`
- `SubagentThreads::ControlPlane.wait!`
- a single snapshot builder that populates `last_snapshot` and `final_snapshot`
- `Cybros::ProgrammableAgent::ExecutionContext` lookup through the thread row rather than subagent metadata
- `Statistics::ToolCallFactProjector` execution-scope attribution through the thread row rather than subagent metadata

Move ownership validation and snapshot assembly out of `lib/cybros/subagent/tools.rb`.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/subagent_threads/control_plane_test.rb test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/lib/cybros/programmable_agent/execution_context_test.rb test/integration/programmable_agent_execution_context_test.rb test/models/conversation_statistics_origin_test.rb test/models/statistics/tool_call_fact_projector_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/app/services/subagent_threads/control_plane.rb cybros/app/services/subagent_threads/snapshot_builder.rb cybros/app/services/subagent_threads/owner_authority.rb cybros/lib/cybros/subagent/tools.rb cybros/lib/cybros/programmable_agent/execution_context.rb cybros/app/services/statistics/tool_call_fact_projector.rb cybros/test/services/subagent_threads/control_plane_test.rb cybros/test/lib/cybros/subagent/tools_test.rb cybros/test/lib/cybros/subagent/run_wait_tools_test.rb cybros/test/lib/cybros/programmable_agent/execution_context_test.rb cybros/test/integration/programmable_agent_execution_context_test.rb cybros/test/models/conversation_statistics_origin_test.rb cybros/test/models/statistics/tool_call_fact_projector_test.rb
git commit -m "refactor: move subagent runtime through control plane"
```

### Task 4: Expand The Kernel-Owned Subagent Tool Contract

**Files:**
- Modify: `cybros/lib/agent_core/resources/tools/tool_name_resolver.rb`
- Modify: `cybros/lib/cybros/programmable_agent/capability_snapshot.rb`
- Modify: `cybros/docs/agent_core/public_api.md`
- Modify: `cybros/docs/dag/subagent_patterns.md`
- Modify: `cybros/test/lib/agent_core/resources/tools/tool_name_resolver_test.rb`
- Modify: `cybros/test/lib/cybros/programmable_agent/capability_snapshot_test.rb`

**Step 1: Write the failing test**

Cover:

- aliases exist for every new subagent tool name variant
- capability snapshots keep the full subagent tool family on kernel-owned routes
- docs describe the expanded subagent runtime surface and control-plane truth correctly

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/lib/agent_core/resources/tools/tool_name_resolver_test.rb test/lib/cybros/programmable_agent/capability_snapshot_test.rb`

Expected: FAIL because only the current four-tool surface is aliased and only `subagent_spawn` / `subagent_run` are reserved as kernel-owned.

**Step 3: Write minimal implementation**

Implement:

- alias coverage for every new subagent tool in `ToolNameResolver`
- kernel-owned reservation for the full subagent tool family in `CapabilitySnapshot`
- matching runtime-contract documentation updates

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/lib/agent_core/resources/tools/tool_name_resolver_test.rb test/lib/cybros/programmable_agent/capability_snapshot_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/lib/agent_core/resources/tools/tool_name_resolver.rb cybros/lib/cybros/programmable_agent/capability_snapshot.rb cybros/docs/agent_core/public_api.md cybros/docs/dag/subagent_patterns.md cybros/test/lib/agent_core/resources/tools/tool_name_resolver_test.rb cybros/test/lib/cybros/programmable_agent/capability_snapshot_test.rb
git commit -m "feat: reserve the full subagent kernel tool contract"
```

### Task 5: Add The Full Owner-Proxy Mutation Surface

**Files:**
- Modify: `cybros/lib/cybros/subagent/tools.rb`
- Modify: `cybros/app/services/subagent_threads/control_plane.rb`
- Create: `cybros/test/scenarios/dag/subagent_thread_owner_proxy_test.rb`
- Modify: `cybros/test/services/subagent_threads/control_plane_test.rb`

**Step 1: Write the failing test**

Cover:

- `subagent_send_input`
- `subagent_resume`
- `subagent_interrupt`
- `subagent_approve`
- `subagent_deny`
- `subagent_close`
- optional `subagent_kill`

Also cover:

- mutations reject when the thread is not `active`
- mutations reject when the caller is not the owner turn
- child browse pages are not a valid mutation path

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/subagent_threads/control_plane_test.rb test/scenarios/dag/subagent_thread_owner_proxy_test.rb`

Expected: FAIL because the tool surface and service methods do not exist yet.

**Step 3: Write minimal implementation**

Implement the mutation tools and route each one through the shared control-plane service. Keep approval explicit with separate approve/deny actions rather than overloading resume or close.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/subagent_threads/control_plane_test.rb test/scenarios/dag/subagent_thread_owner_proxy_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/lib/cybros/subagent/tools.rb cybros/app/services/subagent_threads/control_plane.rb cybros/test/scenarios/dag/subagent_thread_owner_proxy_test.rb cybros/test/services/subagent_threads/control_plane_test.rb
git commit -m "feat: add owner-proxied subagent controls"
```

### Task 6: Freeze Active Child Threads When The Owner Turn Finalizes

**Files:**
- Create: `cybros/app/services/subagent_threads/owner_finalizer.rb`
- Modify: `cybros/app/models/conversation_run_tracker.rb`
- Modify: `cybros/app/models/dag/node.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/test/services/subagent_threads/owner_finalizer_test.rb`
- Modify: `cybros/test/scenarios/dag/subagent_thread_graph_topology_test.rb`

**Step 1: Write the failing test**

Cover:

- owner terminal state freezes all active child threads
- child nonterminal nodes are stopped
- child nonterminal queue rows are canceled
- child pages become read-only after freeze

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/subagent_threads/owner_finalizer_test.rb test/scenarios/dag/subagent_thread_graph_topology_test.rb`

Expected: FAIL because owner finalization does not yet reconcile active child threads.

**Step 3: Write minimal implementation**

Hook owner finalization from the existing run/node terminal tracking path. Prefer one service entry point rather than spreading freeze logic across tools and models.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/subagent_threads/owner_finalizer_test.rb test/scenarios/dag/subagent_thread_graph_topology_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/app/services/subagent_threads/owner_finalizer.rb cybros/app/models/conversation_run_tracker.rb cybros/app/models/dag/node.rb cybros/app/models/conversation.rb cybros/test/services/subagent_threads/owner_finalizer_test.rb cybros/test/scenarios/dag/subagent_thread_graph_topology_test.rb
git commit -m "feat: freeze subagent threads on owner finalization"
```

### Task 7: Materialize Owner Notifications For Non-Owner Child Terminal States

**Files:**
- Create: `cybros/app/services/subagent_threads/terminal_notifier.rb`
- Modify: `cybros/app/services/subagent_threads/control_plane.rb`
- Modify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Modify: `cybros/lib/agent_core/dag/executors/task_executor.rb`
- Modify: `cybros/test/models/conversation/turn_execution_subagent_activity_test.rb`
- Modify: `cybros/test/scenarios/dag/subagent_thread_owner_notification_test.rb`
- Modify: `cybros/test/scenarios/dag/subagent_thread_graph_topology_test.rb`

**Step 1: Write the failing test**

Cover:

- non-owner child failure or unexpected stop records `terminal_origin != owner_action`
- owner receives a parent-side notice/join activity
- normal completion does not create an extra notice node beyond `subagent_wait`

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/conversation/turn_execution_subagent_activity_test.rb test/scenarios/dag/subagent_thread_owner_notification_test.rb test/scenarios/dag/subagent_thread_graph_topology_test.rb`

Expected: FAIL because unexpected child terminal states are not yet promoted into owner-visible notices.

**Step 3: Write minimal implementation**

Implement:

- terminal-origin tracking on `SubagentThread`
- a notifier that materializes parent-owned notice/join work only for abnormal terminal paths
- projector updates so parent run-state prefers `SubagentThread` snapshots over guessing from stale tool output

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/conversation/turn_execution_subagent_activity_test.rb test/scenarios/dag/subagent_thread_owner_notification_test.rb test/scenarios/dag/subagent_thread_graph_topology_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/app/services/subagent_threads/terminal_notifier.rb cybros/app/services/subagent_threads/control_plane.rb cybros/app/models/conversation/turn_execution_projector.rb cybros/lib/agent_core/dag/executors/task_executor.rb cybros/test/models/conversation/turn_execution_subagent_activity_test.rb cybros/test/scenarios/dag/subagent_thread_owner_notification_test.rb cybros/test/scenarios/dag/subagent_thread_graph_topology_test.rb
git commit -m "feat: notify owner on abnormal subagent termination"
```

### Task 8: Make Child Browsing Explicitly Read-Only And Owner-Managed

**Files:**
- Modify: `cybros/app/models/conversation/node_action_policy.rb`
- Modify: `cybros/app/controllers/conversations_controller.rb`
- Modify: `cybros/app/views/conversations/show.html.erb`
- Modify: `cybros/app/views/conversation_messages/_message.html.erb`
- Modify: `cybros/app/javascript/controllers/conversation_channel_controller.js`
- Modify: `cybros/test/models/conversation_node_action_policy_test.rb`
- Create: `cybros/test/system/subagent_thread_read_only_browse_test.rb`

**Step 1: Write the failing test**

Cover:

- child conversation pages show progress and transcript
- direct mutation controls are absent or disabled
- the UI points back to the owner thread for mutation

**Step 2: Run test to verify it fails**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/models/conversation_node_action_policy_test.rb test/system/subagent_thread_read_only_browse_test.rb`

Expected: FAIL because child browse pages still expose normal conversation actions.

**Step 3: Write minimal implementation**

Make child browse pages visibly read-only. Do not allow direct retry, stop, approval, or message submission paths from the child page.

**Step 4: Run test to verify it passes**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/models/conversation_node_action_policy_test.rb test/system/subagent_thread_read_only_browse_test.rb`

Expected: PASS

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/app/models/conversation/node_action_policy.rb cybros/app/controllers/conversations_controller.rb cybros/app/views/conversations/show.html.erb cybros/app/views/conversation_messages/_message.html.erb cybros/app/javascript/controllers/conversation_channel_controller.js cybros/test/models/conversation_node_action_policy_test.rb cybros/test/system/subagent_thread_read_only_browse_test.rb
git commit -m "feat: make subagent browse pages read only"
```

### Task 9: Re-Verify Graph Topology, Run Development Proof, And Write The Report

**Files:**
- Modify: `cybros/test/scenarios/dag/subagent_thread_graph_topology_test.rb`
- Create: `cybros/docs/reports/2026-03-18-subagent-thread-control-plane-proof.md`

**Step 1: Write the final acceptance checks**

Extend the topology test so it proves:

- parent and child graphs stay separate
- expected parent-side join/notice nodes appear only in the intended paths
- no cross-graph merge edges appear
- frozen child threads stay read-only after owner finalization

**Step 2: Run the targeted test suite**

Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/subagent_thread_test.rb test/services/subagent_threads/control_plane_test.rb test/services/subagent_threads/owner_finalizer_test.rb test/scenarios/dag/subagent_thread_graph_topology_test.rb test/scenarios/dag/subagent_thread_owner_proxy_test.rb test/scenarios/dag/subagent_thread_owner_notification_test.rb test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb`

Expected: PASS

**Step 3: Run a real development proof**

Run:

```bash
cd /Users/jasl/Workspaces/Cybros/cybros/cybros
pg_isready
bin/dev
```

Then in the real development app, using browser automation or equivalent local tooling so the proof remains repeatable:

- start a conversation that triggers a subagent
- verify the child is browsable
- force one normal completion path
- force one abnormal child terminal path
- inspect the parent and child DAGs with the existing DAG debug tooling and record the node ids, turn ids, and graph facts

**Step 4: Write the proof report**

Document:

- the prompt used
- owner node id / turn id
- `subagent_id`
- child conversation id
- the observed parent-side join/notice nodes
- proof that no hidden cross-graph merge occurred
- screenshots plus precise transcript/tool or database evidence as appropriate

**Step 5: Commit**

```bash
cd /Users/jasl/Workspaces/Cybros/cybros
git add cybros/test/scenarios/dag/subagent_thread_graph_topology_test.rb cybros/docs/reports/2026-03-18-subagent-thread-control-plane-proof.md
git commit -m "test: prove subagent thread control plane in development"
```

## Final Verification

Before calling this complete:

- Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/models/subagent_thread_test.rb test/services/subagent_threads/control_plane_test.rb test/services/subagent_threads/owner_finalizer_test.rb test/lib/cybros/subagent/tools_test.rb test/lib/cybros/subagent/run_wait_tools_test.rb test/lib/cybros/programmable_agent/execution_context_test.rb test/integration/programmable_agent_execution_context_test.rb test/lib/agent_core/resources/tools/tool_name_resolver_test.rb test/lib/cybros/programmable_agent/capability_snapshot_test.rb test/models/conversation/turn_execution_subagent_activity_test.rb test/models/conversation_statistics_origin_test.rb test/models/statistics/tool_call_fact_projector_test.rb test/scenarios/dag/subagent_thread_graph_topology_test.rb test/scenarios/dag/subagent_thread_owner_proxy_test.rb test/scenarios/dag/subagent_thread_owner_notification_test.rb`
- Run: `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && PARALLEL_WORKERS=1 bin/rails test test/models/conversation_node_action_policy_test.rb test/system/subagent_thread_read_only_browse_test.rb`
- Run one real `bin/dev` development proof and save `docs/reports/2026-03-18-subagent-thread-control-plane-proof.md`

Plan complete and saved to `docs/plans/2026-03-18-subagent-thread-control-plane.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
