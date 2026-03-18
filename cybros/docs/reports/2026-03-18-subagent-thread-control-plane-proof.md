# Subagent Thread Control Plane Proof

Date: 2026-03-18
Environment: `development`
Workspace: `/Users/jasl/Workspaces/Cybros/cybros/cybros`

## Verified Test Suites

Fresh verification command:

```bash
bin/rails test \
  test/models/subagent_thread_test.rb \
  test/services/subagent_threads/control_plane_test.rb \
  test/services/subagent_threads/lifecycle_sync_test.rb \
  test/services/subagent_threads/owner_finalizer_test.rb \
  test/lib/cybros/subagent/tools_test.rb \
  test/lib/cybros/subagent/run_wait_tools_test.rb \
  test/lib/cybros/programmable_agent/execution_context_test.rb \
  test/integration/programmable_agent_execution_context_test.rb \
  test/lib/agent_core/resources/tools/tool_name_resolver_test.rb \
  test/lib/cybros/programmable_agent/capability_snapshot_test.rb \
  test/models/conversation_statistics_origin_test.rb \
  test/models/statistics/tool_call_fact_projector_test.rb \
  test/models/conversation/turn_execution_subagent_activity_test.rb \
  test/integration/conversation_subagent_activity_ui_test.rb \
  test/integration/conversations_test.rb \
  test/models/conversation_node_action_policy_test.rb \
  test/scenarios/dag/programmable_agent_subagent_fanout_test.rb \
  test/scenarios/dag/programmable_agent_subagent_aggregation_test.rb \
  test/scenarios/dag/subagent_thread_graph_topology_test.rb \
  test/lib/agent_core/dag/task_executor_runtime_surface_test.rb \
  test/integration/programmable_agent_prompt_builder_test.rb
```

Observed result:

- `120 runs`
- `1031 assertions`
- `0 failures`
- `0 errors`
- exit status `0`

## Development Proof

I prepared the development database with:

```bash
pg_isready
bin/rails db:prepare RAILS_ENV=development
```

I then created a development-only proof user, parent conversation, and two subagent threads by calling the real `subagent_spawn` / `subagent_close` tool surface inside `RAILS_ENV=development`.

Proof identities and graph ids:

- proof login email: `subagent-proof-665f9925@example.com`
- parent conversation id: `019d0073-1822-701b-a6c5-ebeb27a6a45a`
- parent graph id: `019d0073-1826-781e-b730-a9435a176974`
- owner turn id: `019d0073-187b-732d-97cf-d4f8be9e4fff`
- owner node id: `019d0073-188b-7859-b727-538d56877e75`

### Case A: Abnormal Child Termination Notifies Owner

Subagent ids:

- abnormal subagent id: `019d0073-193f-736e-83ad-052ac1fec889`
- abnormal child conversation id: `019d0073-1942-7160-8d45-5d91437d28fe`
- abnormal child graph id: `019d0073-1942-7dc0-90ef-664e2e6d5811`

Observed thread state after child runtime failure:

```json
{
  "status": "active",
  "child_status": "failed",
  "terminal_origin": "child_runtime",
  "terminal_reason": "development-proof-boom",
  "owner_notified_at": "2026-03-18T10:17:16Z",
  "notice_node_ids": ["019d0073-1a0e-7deb-bd83-fa378e5097cc"]
}
```

Interpretation:

- child runtime failure did not close the thread
- the thread stayed resumable/owner-managed (`status: active`)
- the control plane recorded abnormal terminal attribution
- the owner received a parent-local notice node

### Case B: Owner Action Close Does Not Notify Owner

Subagent ids:

- owner-close subagent id: `019d0073-1a56-7c70-8331-8bf0b69777d0`
- owner-close child conversation id: `019d0073-1a59-7083-99e0-1068f64193b1`
- owner-close child graph id: `019d0073-1a5a-70bb-8a54-938d5fd45812`

Observed thread state after `subagent_close`:

```json
{
  "status": "closed",
  "child_status": "stopped",
  "terminal_origin": "owner_action",
  "terminal_reason": "closed",
  "owner_notified_at": null,
  "notice_count": 0
}
```

Interpretation:

- owner close terminalized the control plane
- child work was stopped
- no owner notice node was materialized for owner-originated termination

## Graph-Structure Evidence

Fresh development query result:

```json
{
  "parent_graph_audit": [],
  "abnormal_child_graph_audit": [],
  "close_child_graph_audit": [],
  "abnormal_owner_trace": {
    "child_graph_id": "019d0073-1942-7dc0-90ef-664e2e6d5811",
    "owner_conversation_id": "019d0073-1822-701b-a6c5-ebeb27a6a45a",
    "owner_turn_id": "019d0073-187b-732d-97cf-d4f8be9e4fff",
    "owner_node_id": "019d0073-188b-7859-b727-538d56877e75"
  },
  "notice_node": {
    "id": "019d0073-1a0e-7deb-bd83-fa378e5097cc",
    "graph_id": "019d0073-1826-781e-b730-a9435a176974",
    "turn_id": "019d0073-187b-732d-97cf-d4f8be9e4fff",
    "body_name": "subagent_notice",
    "subagent_thread_id": "019d0073-193f-736e-83ad-052ac1fec889"
  },
  "close_thread_notice_count": 0
}
```

This confirms:

- parent and child graphs are still separately auditable
- `DAG::GraphAudit` found no topology violations
- owner tracing works at the database layer through `subagent_threads.child_graph_id`
- the abnormal notice node lives on the parent graph, not the child graph
- the close path did not create a stray notice node

## Development HTTP/UI Evidence

I started a development server with:

```bash
bin/rails server -e development -p 3000
```

Then I used a clean `curl` session to sign in as the proof user and fetch the abnormal child conversation page.

Observed HTTP result:

- login POST returned `HTTP/1.1 302 Found`
- signed `session_token` cookie was issued

Observed child page snippets:

```text
254: data-testid="managed-subagent-banner"
257: This subagent is managed by its owner conversation.
258: <a class="link link-primary" data-testid="managed-subagent-owner-link" href="/conversations/019d0073-1822-701b-a6c5-ebeb27a6a45a">Open owner</a>
360: disabled
364: <button type="submit" class="btn btn-neutral btn-circle btn-sm shrink-0 mb-0.5" aria-label="Send" disabled>
```

This confirms the child conversation is browsable but explicitly read-only and owner-managed in the development UI.

## Important Debugging Note

During development proof, I found a real runtime bug that the initial automated tests did not catch:

- `DAG::Node#transition_to!` uses `update_all`
- that bypassed Active Record `after_commit`
- child runtime failures therefore did not notify the owner in the real development path

I fixed this by invoking subagent lifecycle sync directly from the node state-transition hot path and then tightened the lifecycle test so it no longer manually calls the sync service.

## Scope Note

The development proof intentionally validated the subagent control plane and graph invariants without requiring a live LLM/provider setup. Child runtime terminal states were driven through real DAG node transitions in development, which is sufficient for verifying:

- owner tracing
- abnormal notice creation
- owner-action close semantics
- child read-only browsing
- parent/child graph separation
