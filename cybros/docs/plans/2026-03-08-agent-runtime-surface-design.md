# Agent Runtime Surface Design

## Summary

This design defines a new `AgentRuntimeSurface` contract for Cybros.

The target shape is:

- Cybros acts as an **agent OS / agent runtime**, not as the home of agent-specific business logic
- the agent does **not** see DAG internals
- the agent programs against a typed runtime surface over an **execution view**
- dynamic runtime scripts may rewrite turn context, compact context, review tool calls, project tool results, finalize output, and shape error handling
- all dynamic behavior remains bounded by DAG engine invariants, static policy, approval mode, and execution sandbox limits

This is intentionally broader than a narrow tool-approval feature. The goal is to unify several scattered runtime behaviors under one programmable contract:

- prompt hardening
- intent/risk classification
- tool approval suggestion
- tool result redaction and summarization
- oversized output externalization
- context compaction
- final output rewriting

## Status

This document should be treated as an **approved architecture direction** for the Cybros runtime layer.

Recommended sequencing:

1. land the core `AgentRuntimeSurface` contract in `AgentCore`
2. wire it into existing runtime stages with safe no-op defaults
3. preserve existing hard runtime boundaries (policy, approvals, sandbox, DAG state machine)
4. integrate programmable-agent-specific authoring and UX later as a separate design thread

The purpose of this document today is to:

- freeze the runtime boundary
- define the lifecycle surface and decision model
- record how the surface composes with existing DAG/policy/runtime behavior
- leave programmable agent authoring details explicitly out of scope for now

## Goals

- Hide DAG internals from agent logic behind a stable runtime-facing surface.
- Make runtime behavior programmable without making it authoritative over platform safety boundaries.
- Unify prompt rewriting, context compaction, tool review, tool result projection, and output rewriting under one contract.
- Allow dynamic scripts to use local or cheap LLMs for classification, redaction, summarization, and review.
- Preserve auditability, replayability, and durable execution truth.
- Let Cybros provide reusable built-in strategies while still allowing agent-defined behavior.

## Non-goals

- Redesign programmable agent authoring UX, editor UX, or storage model in this pass.
- Expose DAG nodes, edges, or scheduler semantics directly to agent code.
- Let runtime-generated scripts bypass static tool policy, approval requirements, or sandbox limits.
- Make dynamic scripts the canonical source of durable truth for execution.
- Replace every existing runtime heuristic immediately; built-in behavior may remain as fallback implementations.

## Current Problem

Today the runtime already contains multiple partial policy layers, but they are scattered and not exposed as one coherent capability surface.

Current examples include:

1. **Tool authorization and approval**
   - static `allow / deny / confirm` policy decisions
   - `awaiting_approval` task nodes created by the tool loop
   - approval/rejection state transitions handled durably in DAG

2. **Prompt and context budgeting**
   - context turn shrinking in `AgentCore::DAG::ContextBudgetManager`
   - tool-output pruning in `AgentCore::ContextManagement::ToolOutputPruner`
   - summarization in `AgentCore::ContextManagement::Summarizer`

3. **App-layer context compaction**
   - `Conversation::ContextCompactionPlan`
   - `compact_context` tasks generated as explicit preflight work

4. **Programmable agent configuration**
   - bundled profiles and agent metadata can choose defaults
   - but the runtime lifecycle itself is still mostly hardcoded

This means Cybros currently has safety/budget mechanisms, but not one clean programmable runtime contract that an agent can target.

## Design Principle 1: Cybros is an agent OS

The clean boundary is:

- **Cybros runtime decides what can happen**
- **the agent decides what should happen within that envelope**

More concretely:

- Cybros owns DAG orchestration, persistence, replay, approvals, policy ceilings, artifact storage, and sandbox enforcement.
- the programmable agent owns prompt shaping, compaction strategy, risk heuristics, result projection preferences, and similar business logic

This separation should remain stable even if the programmable agent implementation changes later.

## Design Principle 2: The agent sees an execution view, not DAG

The agent should not receive:

- node ids as its primary control surface
- edge semantics
- scheduler claimability
- graph mutation APIs

The agent should receive typed runtime objects such as:

- prompt view
- tool call request
- tool result preview
- output draft
- runtime error

The DAG remains an internal orchestrator, similar to how the App layer uses `Conversation` instead of reaching into DAG internals directly.

## Design Principle 3: Use typed middleware, not generic `on_*` hooks

Generic hooks such as `on_prompt` or `on_tool_call_request` are too weak and ambiguous for this problem.

They do not express:

- whether a stage is read-only or rewrite-capable
- whether a stage is advisory or authoritative
- what object shape enters and exits the stage
- how decisions should merge with static policy

The chosen direction is a **typed middleware surface** with explicit lifecycle methods.

Pure observation events may still exist, but they are separate from rewrite-capable stages.

## Design Principle 4: Dynamic scripts are advisory, not authoritative

The runtime-generated script may recommend decisions and rewrite execution views, but it must remain below platform hard limits.

The final decision order is:

1. platform hard constraints
   - tool existence
   - schema validity
   - sandbox/profile ceilings
   - DAG engine invariants
2. static policy
   - `allow / deny / confirm`
3. runtime surface suggestion
4. user approval mode
5. executor translation into DAG state transitions and actual execution

This means:

- dynamic scripts may **tighten** execution
- dynamic scripts may **request human review**
- dynamic scripts may **rewrite and resubmit for re-evaluation**
- dynamic scripts may **not widen permissions beyond platform policy**

## Design Principle 5: Separate raw data from model-visible projected data

One of the main motivations for this work is that tool outputs can be:

- extremely large
- full of untrusted instructions
- full of secrets or sensitive values

So the runtime must distinguish:

- **raw result**
  - durable
  - audit-visible
  - may live in artifacts/blob storage
- **projected result**
  - safe subset that re-enters model context
  - may be summarized, redacted, truncated, or quarantined

The same principle applies to context compaction:

- raw history remains durable truth
- the agent only decides how to project or compact it for the next execution step

## Chosen Direction: `AgentRuntimeSurface`

The runtime should expose a small typed surface with safe defaults:

```ruby
module AgentCore
  module RuntimeSurface
    class Base
      def prepare_turn(input:) = Decisions::Pass.new
      def compact_context(input:) = Decisions::Pass.new
      def review_tool_call(input:) = Decisions::Pass.new
      def project_tool_result(input:) = Decisions::Pass.new
      def finalize_output(input:) = Decisions::Pass.new
      def handle_error(input:) = Decisions::Pass.new
    end
  end
end
```

This is the runtime contract.

It is separate from:

- the specific programmable agent implementation
- any future authoring DSL
- any future UI/editor for runtime programs

The default implementation should be no-op and safe.

## Observation Events vs Rewrite Stages

Observation-only events may still exist for tracing and metrics:

- `on_turn_started`
- `on_tool_call_finished`
- `on_turn_finished`

But they should remain observational.

Anything that can rewrite data or affect control flow should use verb-based lifecycle methods instead:

- `prepare_turn`
- `compact_context`
- `review_tool_call`
- `project_tool_result`
- `finalize_output`
- `handle_error`

## Proposed Surface Inputs

The surface should receive typed execution-view inputs rather than open-ended hashes.

Suggested first-pass inputs:

```ruby
PrepareTurnInput =
  Data.define(
    :prompt,
    :context,
    :budget,
    :capabilities,
    :helpers,
  )

CompactContextInput =
  Data.define(
    :context_window,
    :budget,
    :capabilities,
    :helpers,
  )

ReviewToolCallInput =
  Data.define(
    :tool_call,
    :context,
    :capabilities,
    :risk_hints,
    :helpers,
  )

ProjectToolResultInput =
  Data.define(
    :tool_call,
    :result_meta,
    :preview,
    :artifact_refs,
    :context,
    :budget,
    :helpers,
  )

FinalizeOutputInput =
  Data.define(
    :draft_output,
    :context,
    :budget,
    :helpers,
  )

HandleErrorInput =
  Data.define(
    :error,
    :stage,
    :context,
    :budget,
    :helpers,
  )
```

### Important constraint

These inputs are **execution views**.

They are not direct DAG mutation payloads.

For example, `ProjectToolResultInput` should contain:

- result metadata
- a preview
- artifact references

and **not** automatically hand the surface the full raw output body.

If the script wants more data, it must request controlled excerpts through helpers and stay within runtime budgets.

## Proposed Decisions

Each stage should return a typed decision object.

Suggested first-pass set:

```ruby
module AgentCore
  module RuntimeSurface
    module Decisions
      Pass = Data.define()

      TurnRewrite =
        Data.define(
          :prompt,
          :metadata,
        )

      ContextCompaction =
        Data.define(
          :kept_items,
          :summaries,
          :externalized_items,
          :metadata,
        )

      ToolCallSuggestion =
        Data.define(
          :action,           # :pass | :allow | :deny | :ask_human | :rewrite_args
          :reason,
          :patched_tool_call,
          :metadata,
        )

      ToolResultProjection =
        Data.define(
          :action,           # :pass | :replace | :externalize | :quarantine
          :projected_result,
          :reason,
          :metadata,
        )

      FinalOutput =
        Data.define(
          :output,
          :metadata,
        )

      ErrorHandling =
        Data.define(
          :action,           # :pass | :user_safe_message | :ask_human | :retryable_mask
          :output,
          :reason,
          :metadata,
        )
    end
  end
end
```

These decisions intentionally express more than `true / false`.

## Stage Semantics

### `prepare_turn`

Purpose:

- harden or rewrite the structured prompt view before the main LLM call
- add or normalize execution hints
- run intent classification or preflight policy logic

Allowed behavior:

- rewrite prompt sections
- add safety notes or metadata
- pass through unchanged

Not allowed:

- direct DAG mutation
- direct tool execution
- bypassing prompt budget ceilings

### `compact_context`

Purpose:

- decide how to shrink context when the current window is too large or when the agent prefers compaction proactively

Allowed behavior:

- choose which prior items to keep verbatim
- request summarization of selected spans
- externalize bulky tool results or older detail
- produce a compacted execution view for the next turn

Important boundary:

- Cybros controls the budget and durable storage
- the agent controls compaction strategy inside that envelope

This means current runtime/app behaviors such as:

- `Conversation::ContextCompactionPlan`
- `compact_context` preflight tasks
- `ToolOutputPruner`

should evolve into either:

- built-in strategies under the runtime surface
- or fallback implementations when the surface passes

Important current-state constraint:

- `compact_context` is already represented as a durable preflight task
- turn execution projection already classifies it as `preflight_task`
- assistant-bubble `run_state` intentionally hides it while broader turn execution still records it

So the first runtime-surface pass should preserve that durable preflight/activity contract unless turn-execution semantics are intentionally redesigned.

### `review_tool_call`

Purpose:

- inspect a tool request before execution and produce an advisory recommendation

Allowed actions:

- `:pass`
- `:allow`
- `:deny`
- `:ask_human`
- `:rewrite_args`

Important merge rules:

- static deny always wins
- static confirm cannot be skipped by the surface
- static allow may be tightened by the surface
- rewritten arguments must be revalidated and re-authorized

### `project_tool_result`

Purpose:

- control what portion of tool output re-enters model context

Allowed actions:

- `:pass`
- `:replace`
- `:externalize`
- `:quarantine`

This stage is the main home for:

- large shell output summarization
- secret redaction
- prompt-injection quarantine
- structured extraction from noisy raw output

### `finalize_output`

Purpose:

- rewrite or normalize the assistant draft before it is shown to the user

Potential uses:

- tone normalization
- output-schema cleanup
- last-mile safety rewrite
- concise finalization after a tool-heavy turn

### `handle_error`

Purpose:

- turn raw runtime/provider/tool errors into safe user-facing behavior without leaking internal detail

Potential uses:

- user-safe rewrites
- escalation to human review
- structured retryability hints
- suppressing noisy implementation detail from the final surface

## Helper API

Dynamic runtime scripts should not get direct access to:

- DAG mutation APIs
- provider objects
- the raw tool registry
- unrestricted network or filesystem access

They should instead receive a small controlled helper layer.

Candidate helpers:

- `classify_intent(...)`
- `score_tool_risk(...)`
- `summarize_tool_result(...)`
- `redact_sensitive_text(...)`
- `load_artifact_excerpt(...)`
- `request_human_review(...)`
- `estimate_tokens(...)`

These helpers are where Cybros can provide:

- local model integrations
- cheap review model integrations
- deterministic utilities
- hard budgets and guardrails

## Merge and Approval Semantics

The runtime surface is advisory middleware.

The merged result for `review_tool_call` should obey the following rules:

- static policy `deny` + surface anything => final `deny`
- static policy `confirm` + surface `allow` => final `confirm` or auto-approved only if user approval mode explicitly allows it
- static policy `allow` + surface `deny` => final `deny`
- static policy `allow` + surface `ask_human` => final `confirm`
- static policy `allow` + surface `rewrite_args` => rerun validation + static policy on the patched call
- surface `pass` => follow static policy unchanged

User approval mode should be modeled separately from surface logic.

Suggested user-facing approval modes:

- `manual_only`
- `auto_accept_safe_suggestions`
- `auto_accept_all_in_policy_scope`

Even the loosest mode still remains constrained by:

- static policy ceilings
- DAG engine semantics
- sandbox/runtime hard caps

## Tool Result Projection Model

The runtime should adopt **archive first, project second** semantics.

The canonical flow is:

1. execute tool
2. persist raw result or raw result artifacts
3. build `result_meta`, `preview`, and `artifact_refs`
4. call `project_tool_result`
5. produce a model-visible `projected_result`
6. feed only the projected result back into prompt assembly

This means the runtime should avoid treating the raw `ToolResult` as identical to the model-visible tool message.

The projected result may be:

- a summary
- a head/tail excerpt
- a structured extraction
- a quarantine stub
- an externalized placeholder

Important current-state constraint:

- turn execution projection and `run_state` UI already read task output previews as user/operator-visible activity state
- replay/refresh correctness already depends on that durable projection chain

So the first runtime-surface pass must explicitly preserve or replace that contract. If model-visible projection and activity preview diverge, both need distinct durable shapes.

## Context Compaction Model

Context compaction should also move into the runtime surface.

This does **not** mean the runtime stops enforcing budgets.

Instead:

- Cybros decides available context budget and durable compaction mechanisms
- the agent decides compaction strategy through `compact_context`

This preserves a clean `can vs should` split:

- runtime: hard limits, durable summary/task machinery, transcript reads, artifact storage
- agent: keep/summarize/externalize strategy

The first pass may still reuse current transient or task-based compaction paths internally, but the policy decision should move behind the surface.

## Runtime Script Constraints

Because runtime scripts may be generated or modified dynamically, they must be treated as untrusted advisory logic.

Required constraints:

- per-stage timeout
- per-stage output-size cap
- bounded helper calls
- bounded helper model usage
- no direct DAG access
- no direct unrestricted tool execution
- no bypass of static policy or sandbox ceilings

Fallback defaults should be stage-specific:

- `prepare_turn` failure => pass through
- `compact_context` failure => runtime fallback compaction behavior
- `review_tool_call` failure => static policy only
- `project_tool_result` failure => runtime fallback projection/redaction/truncation
- `finalize_output` failure => original draft output
- `handle_error` failure => runtime default error path

## Audit and Observability

Each runtime-surface stage should produce durable audit facts at three layers:

1. **surface input snapshot**
   - summarized execution-view input
2. **surface decision**
   - stage
   - decision
   - reason
   - timing
   - script version/hash
3. **merged final outcome**
   - static policy result
   - user approval mode effect
   - executor/DAG result

For tool-result projection specifically, audit should distinguish:

- `raw_result_ref`
- `projected_result`
- `projection_metadata`

This is required for later debugging of:

- why a tool was auto-approved
- why a dangerous output was quarantined
- why a large shell result did not re-enter context

## Integration With Existing Runtime

The first-pass integration points are:

1. `AgentCore::DAG::Runtime`
   - add a `runtime_surface`
   - add helper/runtime budgets

2. `Cybros::AgentRuntimeResolver`
   - construct the surface from profile/program configuration
   - inject surface-specific execution context attributes

3. `AgentCore::DAG::ContextBudgetManager`
   - call `prepare_turn`
   - call `compact_context`
   - keep budget enforcement in runtime

4. `AgentCore::DAG::Executors::AgentMessageExecutor`
   - call `review_tool_call`
   - merge with static policy
   - call `finalize_output`

5. `AgentCore::DAG::Executors::TaskExecutor`
   - produce raw result artifacts/preview
   - call `project_tool_result`

6. `Conversation::TurnExecutionProjector`
   - continue projecting durable task/preflight activity truth
   - preserve `composer_only` vs `assistant_bubble` visibility semantics unless intentionally redesigned
   - decide whether activity output preview uses projected result or a separate safe preview

7. error handling path
   - call `handle_error` before exposing final user-visible errors

Existing pieces should migrate into built-in fallback strategies rather than disappear immediately:

- `ToolOutputPruner`
- summarizer-based compaction
- app-layer context compaction planning
- existing static tool policy

## Boundary With Programmable Agent Work

This document intentionally stops at the runtime contract.

Deferred to a later discussion:

- how programmable agents author or edit runtime scripts
- whether the script language is Ruby, JS, or another embedded DSL
- how scripts are stored and versioned in `AgentProgram`
- how agent authors debug runtime-surface decisions

What is fixed now is only the runtime boundary:

- Cybros exposes the surface
- Cybros enforces the hard limits
- programmable agents are one future consumer of that surface

## Open Questions

- What embedded script language should first implement the runtime surface?
- How should script snapshots be persisted for replay and audit?
- Should `compact_context` be able to request durable summary-node materialization directly in v1, or only return a projected view?
- How much of `projected_result` should be stored as node output preview versus transient prompt-only projection?
- Should approval-mode selection live on conversation metadata, account settings, agent profile, or multiple scopes?
