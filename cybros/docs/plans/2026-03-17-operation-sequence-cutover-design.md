# Operation Sequence Cutover Design

## Status

Approved design for the post-audit kernel/program cutover on March 17, 2026.

This document is written against the current code reality:

- direct LLM-authored tool calls still materialize DAG task nodes inside `AgentCore::DAG::Executors::AgentMessageExecutor#expand_tool_loop!`
- programmable hook `create_task(append)` already uses durable `turn_internal_tasks`
- bootstrap authority tools (`cybros_seed_message`, `cybros_generate_title`, `cybros_enqueue_lane_summary`) already exist as kernel-built tools
- workspace bootstrap is duplicated in both `cybros` and bundled `claw`

This design intentionally supersedes the audit's default recommendation to move `memory` into `cybros`. `memory` remains a program-side experiment surface in this cutover.

## Problem

The current runtime still has two different admitted operation paths:

1. direct agent tool calls go straight from model output to DAG task nodes
2. hook-authored append work goes through `turn_internal_tasks` before later DAG materialization

That split keeps the kernel/program boundary muddy:

- bootstrap and hook-authored sequences use queue-first admission
- normal tool use bypasses the queue
- observability and audit data are not uniform
- built-in runtime tools and agent-proxied tools do not share the same admission lifecycle

The audit also found three additional problems that should be solved in the same cutover:

- `workspace bootstrap` content and authority are still mixed together
- dead `execution_target` compatibility logic still exists in bundled `claw`
- `before_agent_step` still ships fixture-only scenario branches in the real production hook

## Goals

- make admitted operations queue-first by default
- reuse existing `turn_internal_tasks` instead of inventing a new durable execution entity
- introduce a thin `OperationSequence` programming model for request-scoped sequencing
- keep the execution path shared for kernel built-ins, bundled-agent tools, bootstrap work, and direct tool calls
- keep `memory` owned by `claw`, including flush timing and write strategy
- make bootstrap authority explicit: `claw` proposes, `cybros` admits, approves, executes, and audits
- delete dead compatibility surfaces instead of preserving them

## Non-Goals

- no attempt to preserve old queue payload shapes for backward compatibility
- no new workflow engine, branching DSL, or compensation semantics
- no new durable `operation_sequences` table
- no operation-level public state machine
- no attempt to move `memory` policy into `cybros` in this cut

## Hard Rules

### One Path Rule

`memory` may remain an ownership exception, but it is not an execution-path exception.

Whenever `claw` asks the runtime to do work, that work should use the same admitted operation path as other runtime work whenever that is practical:

`proposal or tool call -> validation -> turn_internal_tasks -> DAG task -> approval if needed -> execution -> receipt`

This rule applies to turn-scoped work. Pre-turn bootstrap is a bounded exception in this cut unless the implementation first introduces a synthetic bootstrap turn and anchor node.

### No New Durable Entity Rule

The durable queue remains `turn_internal_tasks`.

`OperationSequence` is an in-memory request-scoped collector, not a new database model. After validation, it flushes into one or more existing `turn_internal_tasks` rows.

### No Compatibility Rule

This cut is intentionally destructive.

- remove dead compatibility fields and branches instead of translating them forward
- if the database shape or stored rows become incompatible, reset the database instead of carrying migration shims
- old hook payloads and old queue payloads do not need adapters if the replacement path is already defined in this document

## Ownership Model

### `cybros` owns

- admission into `turn_internal_tasks`
- DAG materialization
- approval and permission checks
- queue ordering and task execution lifecycle
- receipts, audit data, and tool call projection
- bootstrap authority and workspace bootstrap lifecycle
- built-in runtime tools such as `subagent_spawn`, `subagent_run`, and bootstrap authority tools

### `claw` owns

- prompt/bootstrap authoring
- bootstrap proposal content
- agent-owned tool implementations
- `memory` policy
  - when to flush
  - what to write
  - append vs replace strategy
  - experimental search/retrieval behavior

## Operation Envelope

The admitted call shape should stay as close as possible to existing task body input and existing tool call shapes.

Every admitted operation call should carry a common envelope with these fields:

- `tool_call_id`
- `logical_tool_name`
- `arguments`
- `reason`
- `origin`
- `approval_hint`
- `idempotency_key`

Notes:

- `reason` and `origin` are the minimum new audit fields that should become normal for runtime-authored calls
- `approval_hint` is advisory metadata, not a second approval system
- `idempotency_key` may be omitted for simple one-shot calls, but bootstrap and generated sequences should always set it

## OperationSequence

`OperationSequence` is the request-scoped collector used by both kernel code and bundled-agent integration code.

Recommended programming shape:

```ruby
seq = OperationSequence.new(origin: "bootstrap_proposal")

seq << OperationCall.tool(
  logical_tool_name: "exec",
  arguments: { "command" => "bundle check" },
  reason: "Verify dependencies",
  idempotency_key: "bootstrap.bundle_check"
)

seq << OperationCall.subagent_spawn(
  arguments: { "name" => "worker", "prompt" => "inspect the failure" },
  reason: "Delegate repo inspection"
)
```

Important constraints:

- `OperationSequence` is append-only
- V1 supports strict ordering only
- no branching
- no compensation
- no public sequence status model
- once validated, each step becomes a normal `turn_internal_tasks` row

## Queue Admission Model

After validation, admitted operations are written into existing `turn_internal_tasks` rows.

This cut should prefer metadata reuse over schema growth:

- keep using `logical_tool_name`
- keep using `input`
- keep using `authored_metadata`
- encode shared sequence metadata in `authored_metadata`
- only add schema fields if the existing row shape cannot carry a required value cleanly

Suggested `authored_metadata` additions for queued operation rows:

- `origin`
- `reason`
- `approval_hint`
- `idempotency_key`
- `sequence_id`
- `step_index`
- `step_count`

If validation fails before admission, the operation is not queued. This design does not introduce a new public operation-status layer for those failures.

## Direct Tool Calls

Direct LLM-authored tool calls should stop creating DAG task nodes inside `AgentMessageExecutor#expand_tool_loop!` once they have been validated for admission.

The new flow is:

1. resolve and validate the requested tool
2. apply policy and runtime-surface review
3. compute approval preview if needed
4. build one or more `OperationCall` objects
5. create the shared continuation agent node needed for the current turn, if the tool loop requires follow-up execution
6. enqueue them into `turn_internal_tasks`
7. let the existing scheduler/materializer splice queued task nodes ahead of that continuation later

This keeps validation close to the point where the model emitted the call, but moves execution staging onto the same queue-backed path already used by other internal operations.

Important implementation note:

- current `TurnInternalTasks::Materializer` only knows how to splice continuations for task-sourced rows
- direct tool-loop rows are sourced from an `agent_message`
- the cut therefore has to teach the materializer how to preserve the shared continuation node for agent-message sourced direct tool calls

## Built-In Tools And Agent-Proxied Tools

The envelope and lifecycle are shared, but the executor is not required to be identical.

- built-in runtime tools continue to execute through kernel-owned implementations
- agent-owned tools continue to route through `tool.execute`
- both paths use the same admitted operation envelope, queue admission, DAG task materialization, approval surface, and receipts

This is especially important for:

- `subagent_spawn`
- `subagent_run`
- `cybros_seed_message`
- `cybros_generate_title`
- `cybros_enqueue_lane_summary`

## Bootstrap

Bootstrap should be split into content vs authority.

### `claw` owns

- what bootstrap work should happen
- which files/dependencies should be prepared
- which ordered steps make sense for this agent

### `cybros` owns

- whether bootstrap work is admitted
- approval and permission handling
- idempotent queueing
- execution and receipts
- the durable fact that bootstrap has or has not been applied

Bootstrap work is therefore just a sequence of admitted operations, not a special side channel, except for the narrow pre-turn `on_conversation_created` case if no synthetic bootstrap turn is introduced in this cut.

## Workspace Bootstrap

The repository currently has duplicated workspace bootstrappers:

- `cybros/app/services/agents/workspace_bootstrap.rb`
- `agents/claw/lib/cybros/agents/claw/workspace_bootstrap.rb`

This cut should collapse those two implementations into a single surviving implementation.

The surviving implementation should:

- remain content-driven by bundled `claw`
- be invoked under kernel authority from `cybros`
- include the `claw`-specific daily memory file seeding if that behavior still belongs to the bundled agent

## Memory Exception

`memory` remains intentionally owned by `claw` in this cut.

That means:

- `claw` keeps `memory_get`, `memory_search`, and `memory_store`
- `claw` keeps deciding whether context pressure should prepend a memory flush before compaction
- `cybros` keeps only the callback-backed persistence services that `claw` already calls

This is an explicit experimental carve-out, not an accident.

## Delete / Collapse Work

This cut should remove the following instead of adapting them:

- dead `execution_target.list` logic and `planning.execution_target_proposal`
- test/support leftovers that still normalize `execution_target.list` as a live callback method
- fixture/scenario behavior from the production `before_agent_step` hook
- duplicate workspace bootstrap implementations
- compatibility-only runtime payload branches that only exist to support old queue or workspace naming

## Destructive Migration Notes

This cut is allowed to reset local state.

If schema changes or payload rewrites leave development data incompatible:

- reset the development database
- reset the test database
- do not add compatibility code solely to rescue old rows

The implementation plan should assume:

- PostgreSQL readiness must be checked with `pg_isready` before Rails verification commands
- if PostgreSQL is not running, start it using the repository/environment instructions before continuing

## Verification Requirements

No completion claim is valid unless all of these succeed on the refactored code:

- targeted unit and integration tests for queue admission, materialization, bootstrap, and subagent paths
- `bin/ci`
- `bin/ci_e2e`
- one real `bin/dev` conversation proving the new unified path works end-to-end with a live model provider

The live verification should prove at least:

- the conversation boots normally
- a normal tool call is admitted onto the queue and executes successfully
- a bootstrap-generated sequence lands on the queue and runs in order
- a `subagent_spawn` or `subagent_run` operation still works
- the runtime does not need compatibility shims to complete the flow
