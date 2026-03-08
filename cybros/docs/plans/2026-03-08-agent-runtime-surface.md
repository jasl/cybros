# Agent Runtime Surface Implementation Plan

> **Update 2026-03-09:** Any programmable-agent integration language in this plan predates the deployment-registration model in `docs/plans/2026-03-09-agent-deployment-connection-design.md`. Do not use bundled agent profiles or `agent_profile_config` as the v1 integration path for external programmable agents.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce a typed `AgentRuntimeSurface` so Cybros can act as an agent OS: hiding DAG internals from agent logic while making turn preparation, context compaction, tool-call review, tool-result projection, output finalization, and error shaping programmable under hard platform safety bounds.

**Architecture:** Add a no-op `AgentRuntimeSurface` contract to `AgentCore`, then thread it through `AgentCore::DAG::Runtime` and `Cybros::AgentRuntimeResolver`. Keep DAG, static tool policy, approvals, and sandbox ceilings authoritative; treat the surface as advisory middleware over execution views. Reuse existing budgeting, pruning, summarization, and compaction machinery as built-in fallback strategies while progressively moving decision-making behind the surface.

**Tech Stack:** Ruby 4.0, Rails 8 alpha, ActiveSupport tests, AgentCore DAG runtime/executors, `Conversation` facade and compaction helpers, Cybros runtime resolver, internal runtime-surface plumbing, programmable agent metadata.

## Coordination Note

This plan intentionally stops at the **runtime layer**.

It may introduce enough loader/config plumbing for programmable agents to opt into runtime surfaces, but it should not redesign programmable-agent authoring, editing, or UX in the same implementation pass.

Any references below to bundled profiles or `agent_profile_config` are legacy internal plumbing references for the current codebase, not the recommended external programmable-agent architecture.

Also important: turn-execution activity projection is already landed in the current codebase. This plan should reuse:

- structured task activity events
- `Conversation::TurnExecutionProjector`
- replay/refresh event-cursor logic
- assistant-bubble `run_state` projection

It should not assume that preflight/task execution UI truth still needs to be invented from scratch.

## Execution posture

This plan assumes the current experimental delivery mode:

- breaking changes are allowed
- backward compatibility is not required
- compatibility shims should be avoided unless they reduce concrete implementation risk
- database reset / clearing local data is acceptable when it simplifies the implementation
- no task in this plan should be blocked on preserving old runtime-surface-adjacent behavior purely for migration comfort

## Execution order and dependency constraints

Recommended order:

1. Task 1 (`surface core contract`)
2. Task 2 (`surface runner and helper sandbox`)
3. Task 3 (`runtime + resolver plumbing`)
4. Task 4 (`prepare_turn + compact_context integration`)
5. Task 5 (`review_tool_call merge path`)
6. Task 6 (`raw vs projected tool result`)
7. Task 7 (`finalize_output + handle_error`)
8. Task 8 (`audit and observability`)
9. Task 9 (`programmable-agent opt-in plumbing`)
10. Task 10 (`docs and final verification`)

Hard dependencies:

- Task 1 must land before everything else.
- Task 2 must land before Tasks 4 through 9 because all stage integrations depend on one execution sandbox for surface code.
- Task 3 must land before Tasks 4 through 9 because the runtime must carry the surface instance and helper budgets.
- Task 4 must land before Task 7 because final output handling should operate on the post-compaction prompt flow.
- Task 5 must land before Task 9 because programmable-agent opt-in needs a stable tool-review merge contract.
- Task 6 must land before Task 10 because verification must prove model-visible results no longer depend on raw output bodies.
- Task 8 should land before Task 9 so programmable-agent integration inherits stable audit hooks.

## Acceptance criteria

This plan is complete only when all of the following are true:

- `AgentCore::DAG::Runtime` carries a validated `runtime_surface` with a safe no-op default.
- all runtime-surface lifecycle stages use typed inputs and typed decisions rather than boolean hooks.
- the runtime surface remains advisory only; static policy, DAG invariants, approvals, and sandbox ceilings still decide final authority.
- `prepare_turn`, `compact_context`, `review_tool_call`, `project_tool_result`, `finalize_output`, and `handle_error` are all wired into the runtime with safe fallback behavior.
- surface failure cannot break turn correctness; every stage falls back to a bounded runtime-owned default path.
- preflight compaction work still remains durably visible in turn execution while assistant-bubble `run_state` keeps current visibility semantics.
- raw tool results are no longer treated as identical to model-visible projected results.
- replay, refresh, and debug/export surfaces remain correct when activity preview and model-visible projection differ.
- audit/observability captures safe summarized stage inputs, decisions, and merged outcomes without logging sensitive raw bodies.
- the first pass does not depend on solving programmable-agent authoring UX or a general-purpose script engine.
- the focused tests added across the tasks are green.
- broader regression checks across `test/lib/agent_core`, `test/lib/cybros`, `test/models/conversation`, and the relevant integration/channel tests are green.

## Progress

- [x] Task 1: surface core contract
  Verified with `bin/rails test test/lib/agent_core/runtime_surface_contract_test.rb test/lib/agent_core/dag/runtime_token_counter_default_test.rb`
- [x] Task 2: surface runner and helper sandbox
  Verified with `bin/rails test test/lib/agent_core/runtime_surface_runner_test.rb`
- [x] Task 3: runtime + resolver plumbing
  Verified with `bin/rails test test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/agent_profile_config_test.rb`
- [x] Task 4: prepare_turn + compact_context integration
  Verified with `bin/rails test test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/models/conversation/context_compaction_plan_test.rb`
  Regression checks: `bin/rails test test/lib/agent_core/dag/context_budget_manager_prompt_sections_test.rb` and `bin/rails test test/models/conversation/turn_execution_projection_visibility_test.rb`
- [x] Task 5: review_tool_call merge path
  Verified with `bin/rails test test/lib/agent_core/dag/agent_message_executor_runtime_surface_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`
- [x] Task 6: raw vs projected tool result
  Verified with `bin/rails test test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb`
  Regression checks: `bin/rails test test/models/conversation/turn_execution_projector_test.rb test/integration/conversation_messages_refresh_execution_test.rb test/lib/agent_core/dag/task_executor_activity_events_test.rb test/models/conversation/turn_execution_subagent_activity_test.rb` and `bin/rails test test/lib/agent_core/resources/tools/tool_result_test.rb`
- [x] Task 7: finalize_output + handle_error
  Verified with `bin/rails test test/lib/agent_core/dag/agent_output_finalization_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`
  Regression checks: `bin/rails test test/lib/agent_core/dag/agent_message_executor_runtime_surface_test.rb test/lib/agent_core/dag/agent_message_executor_activity_events_test.rb` and `bin/rails test test/scenarios/dag/agent_core_dag_integration_flow_test.rb -i '/retryable provider failure exhausts recovery attempts and leaves the node errored|non-retryable validation error does not retry the primary call|streaming: non-retryable provider error before output does not retry|streaming: validation error subclasses before output do not retry/'`
- [x] Task 8: audit and observability
  Verified with `bin/rails test test/lib/agent_core/runtime_surface_audit_test.rb`
  Regression checks: `bin/rails test test/lib/agent_core/runtime_surface_runner_test.rb test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/models/conversation/context_compaction_plan_test.rb test/lib/agent_core/dag/agent_message_executor_runtime_surface_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/lib/agent_core/dag/agent_output_finalization_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`
- [x] Task 9: programmable-agent opt-in plumbing
  Verified with `bin/rails test test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb`
  Regression checks: `bin/rails test test/lib/cybros/agent_profile_config_test.rb`
- [x] Task 10: docs and final verification
  Focused verification: `bin/rails test test/lib/agent_core/runtime_surface_contract_test.rb test/lib/agent_core/dag/runtime_token_counter_default_test.rb test/lib/agent_core/runtime_surface_runner_test.rb test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/agent_profile_config_test.rb test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/models/conversation/context_compaction_plan_test.rb test/lib/agent_core/dag/agent_message_executor_runtime_surface_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb test/lib/agent_core/dag/agent_output_finalization_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb test/lib/agent_core/runtime_surface_audit_test.rb test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb`
  Broader regression: `bin/rails test test/lib/agent_core test/lib/cybros test/models/conversation test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb`

---

## Task 1: Add the core `AgentRuntimeSurface` contract and safe no-op defaults

### Task 1 Files

- Create: `cybros/lib/agent_core/runtime_surface.rb`
- Create: `cybros/lib/agent_core/runtime_surface/base.rb`
- Create: `cybros/lib/agent_core/runtime_surface/decisions.rb`
- Create: `cybros/lib/agent_core/runtime_surface/inputs.rb`
- Modify: `cybros/lib/agent_core.rb`
- Modify: `cybros/lib/agent_core/dag/runtime.rb`
- Test: `cybros/test/lib/agent_core/dag/runtime_token_counter_default_test.rb`
- Test: create `cybros/test/lib/agent_core/runtime_surface_contract_test.rb`

### Task 1 / Step 1: Write the failing test

Add coverage that proves:

- `AgentCore::DAG::Runtime` accepts a `runtime_surface`
- the default surface is a safe no-op implementation
- each lifecycle method returns a typed decision object rather than `true / false`
- invalid surface objects are rejected early

### Task 1 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/agent_core/runtime_surface_contract_test.rb test/lib/agent_core/dag/runtime_token_counter_default_test.rb
```

Expected: FAIL because no runtime-surface contract exists yet.

### Task 1 / Step 3: Write minimal implementation

Introduce:

- the surface namespace
- typed input/decision objects
- a no-op base implementation
- runtime validation and defaulting inside `AgentCore::DAG::Runtime`

Do not add programmable-agent-specific logic yet.

### Task 1 / Step 4: Run test to verify it passes

Run the same test command again.

Expected: PASS

## Task 2: Add a runtime-surface runner and controlled helper sandbox

### Task 2 Files

- Create: `cybros/lib/agent_core/runtime_surface/runner.rb`
- Create: `cybros/lib/agent_core/runtime_surface/helpers.rb`
- Create: `cybros/lib/agent_core/runtime_surface/errors.rb`
- Modify: `cybros/lib/agent_core/execution_context.rb`
- Modify: `cybros/lib/agent_core/observability/instrumenter.rb` if new stage events need contract support
- Test: create `cybros/test/lib/agent_core/runtime_surface_runner_test.rb`

### Task 2 / Step 1: Write the failing test

Add tests that prove:

- each stage runs through one common runner
- per-stage timeout and output-size limits are enforced
- helper access is constrained to the approved helper API
- runner failures return stage-appropriate fallback behavior instead of raising through the whole turn

### Task 2 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/agent_core/runtime_surface_runner_test.rb
```

Expected: FAIL because no runner/helper sandbox exists yet.

### Task 2 / Step 3: Write minimal implementation

Implement:

- a single surface runner
- helper injection
- stage-scoped budgets/timeouts
- fallback classification for runner failures

Keep the helper API small and do not grant DAG or raw runtime object access.

### Task 2 / Step 4: Run test to verify it passes

Run the same test again.

Expected: PASS

## Task 3: Thread `runtime_surface` through runtime resolution

### Task 3 Files

These file references describe legacy internal plumbing only. They are not the registration or deployment model for external programmable agents.

- Modify: `cybros/lib/cybros/agent_runtime_resolver.rb`
- Modify: `cybros/lib/cybros/agent_profile_config.rb`
- Modify: `cybros/cybros-agent/profiles/default-assistant/agent.yml`
- Test: `cybros/test/lib/cybros/agent_runtime_resolver_test.rb`
- Test: `cybros/test/lib/cybros/agent_profile_config_test.rb`

### Task 3 / Step 1: Write the failing test

Add coverage that proves:

- runtime resolution can build a `runtime_surface`
- agent profile config can express safe runtime-surface configuration
- missing/invalid runtime-surface config falls back to the no-op surface
- surface-related execution-context attributes are normalized safely

### Task 3 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/cybros/agent_runtime_resolver_test.rb test/lib/cybros/agent_profile_config_test.rb
```

Expected: FAIL because runtime resolution does not yet know about `runtime_surface`.

### Task 3 / Step 3: Write minimal implementation

Extend runtime resolution to:

- accept runtime-surface config
- construct a no-op or configured surface
- carry helper budgets / execution-context attributes needed by the runner

Do not yet wire stage execution into prompt/tool/output flow.

### Task 3 / Step 4: Run test to verify it passes

Run the same tests again.

Expected: PASS

## Task 4: Integrate `prepare_turn` and `compact_context` into prompt budgeting

### Task 4 Files

- Modify: `cybros/lib/agent_core/dag/context_budget_manager.rb`
- Modify: `cybros/app/models/conversation/context_compaction_plan.rb`
- Modify: `cybros/app/models/conversation.rb`
- Modify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Test: `cybros/test/lib/agent_core/dag/context_budget_manager_prompt_sections_test.rb`
- Test: create `cybros/test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb`
- Test: create `cybros/test/models/conversation/context_compaction_plan_test.rb`
- Test: `cybros/test/models/conversation/turn_execution_projection_visibility_test.rb`

### Task 4 / Step 1: Write the failing test

Add tests that prove:

- `prepare_turn` can rewrite the execution prompt view before the main model call
- `compact_context` can influence keep/summarize/externalize decisions
- runtime budget limits still win when the surface requests too much context
- current app-layer compaction still has a safe fallback path when the surface passes or fails
- durable preflight-task projection still records compaction work and keeps it `composer_only` for assistant-bubble `run_state`

### Task 4 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/agent_core/dag/context_budget_manager_runtime_surface_test.rb test/models/conversation/context_compaction_plan_test.rb
```

Expected: FAIL because context budgeting does not yet consult the runtime surface.

### Task 4 / Step 3: Write minimal implementation

Wire the runner into:

- prompt preparation
- context compaction
- fallback pruner/summarizer logic

Keep the runtime authoritative over:

- token budget
- compaction mechanism
- durable transcript reads

Preserve the current durable preflight-task shape so turn-execution projection and replay semantics stay truthful while compaction policy moves behind the surface.

### Task 4 / Step 4: Run test to verify it passes

Run the same tests again.

Expected: PASS

## Task 5: Integrate `review_tool_call` and merge it with static tool policy

### Task 5 Files

- Modify: `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Modify: `cybros/lib/agent_core/resources/tools/policy/decision.rb` if explicit merge helpers are needed
- Possibly create: `cybros/lib/agent_core/runtime_surface/tool_call_merge.rb`
- Test: create `cybros/test/lib/agent_core/dag/agent_message_executor_runtime_surface_test.rb`
- Test: `cybros/test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb`

### Task 5 / Step 1: Write the failing test

Add coverage that freezes:

- static `deny` always wins
- static `confirm` cannot be bypassed by surface `allow`
- static `allow` can be tightened to `deny` or `ask_human`
- `rewrite_args` causes revalidation and re-authorization
- runner failure falls back to static policy only

### Task 5 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/agent_core/dag/agent_message_executor_runtime_surface_test.rb test/lib/cybros/agent_runtime_resolver_tool_policy_test.rb
```

Expected: FAIL because tool-review suggestions are not part of the current tool loop.

### Task 5 / Step 3: Write minimal implementation

Integrate `review_tool_call` before task creation and merge the result with:

- hard validation
- static policy
- approval mode defaults

Do not let the surface widen permissions beyond existing policy ceilings.

### Task 5 / Step 4: Run test to verify it passes

Run the same tests again.

Expected: PASS

## Task 6: Split raw tool results from projected tool results

### Task 6 Files

- Modify: `cybros/lib/agent_core/dag/executors/task_executor.rb`
- Modify: `cybros/lib/agent_core/resources/tools/tool_result.rb`
- Modify: `cybros/lib/agent_core/dag/context_adapter.rb`
- Modify: `cybros/app/models/conversation/turn_execution_projector.rb`
- Possibly create: `cybros/lib/agent_core/runtime_surface/tool_result_projection.rb`
- Test: create `cybros/test/lib/agent_core/dag/task_executor_runtime_surface_test.rb`
- Test: create `cybros/test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb`
- Test: `cybros/test/models/conversation/turn_execution_projector_test.rb`
- Test: `cybros/test/integration/conversation_messages_refresh_execution_test.rb`

### Task 6 / Step 1: Write the failing test

Add tests that prove:

- raw result metadata/preview/artifact refs are preserved durably
- `project_tool_result` controls what re-enters prompt context
- `externalize` and `quarantine` produce safe projected results
- fallback projection still redacts/truncates when the surface fails
- activity previews and refresh/replay stay correct when raw result and model-visible projected result diverge

### Task 6 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/agent_core/dag/task_executor_runtime_surface_test.rb test/lib/agent_core/dag/context_adapter_projected_tool_result_test.rb
```

Expected: FAIL because raw and projected tool results are not distinct today.

### Task 6 / Step 3: Write minimal implementation

Refactor task execution so the durable flow becomes:

1. execute tool
2. persist raw result data and preview/materialization metadata
3. call `project_tool_result`
4. persist the projected result that prompt assembly should consume

Do not hand the surface unlimited raw output by default; prefer preview plus controlled artifact access.

Explicitly decide and implement whether turn-execution activity previews use:

- the projected result
- or a separate safe activity preview derived alongside it

Update `Conversation::TurnExecutionProjector` accordingly so UI/debug/replay consumers keep a stable contract.

### Task 6 / Step 4: Run test to verify it passes

Run the same tests again.

Expected: PASS

## Task 7: Integrate `finalize_output` and `handle_error`

### Task 7 Files

- Modify: `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`
- Modify: `cybros/lib/dag/runner.rb` if final error translation belongs there
- Modify: `cybros/lib/agent_core/dag/context_adapter.rb` if output projection contracts need matching shape
- Test: create `cybros/test/lib/agent_core/dag/agent_output_finalization_test.rb`
- Test: create `cybros/test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`

### Task 7 / Step 1: Write the failing test

Add coverage that proves:

- assistant drafts can be rewritten by `finalize_output`
- runtime/provider/tool errors can be mapped to user-safe outputs by `handle_error`
- failures in these stages degrade safely without breaking the whole turn

### Task 7 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/agent_core/dag/agent_output_finalization_test.rb test/lib/agent_core/dag/runtime_surface_error_handling_test.rb
```

Expected: FAIL because no finalization/error surface is wired yet.

### Task 7 / Step 3: Write minimal implementation

Hook:

- `finalize_output` into the successful assistant-output path
- `handle_error` into the user-visible error path

Preserve existing safe fallback behavior if the surface passes or fails.

### Task 7 / Step 4: Run test to verify it passes

Run the same tests again.

Expected: PASS

## Task 8: Add runtime-surface audit and observability

### Task 8 Files

- Modify: `cybros/lib/agent_core/execution_context.rb`
- Modify: `cybros/lib/agent_core/observability/trace_recorder.rb`
- Modify: `cybros/lib/agent_core/observability/null_instrumenter.rb` if default no-op stage publishing needs updates
- Possibly create: `cybros/lib/agent_core/runtime_surface/audit_serializer.rb`
- Test: create `cybros/test/lib/agent_core/runtime_surface_audit_test.rb`

### Task 8 / Step 1: Write the failing test

Add tests that prove each stage records:

- summarized input snapshot
- stage decision
- fallback/timeout outcome
- merged final outcome metadata where applicable

Special attention:

- raw tool result reference vs projected result
- script version/hash or equivalent identity

### Task 8 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/lib/agent_core/runtime_surface_audit_test.rb
```

Expected: FAIL because no runtime-surface audit contract exists yet.

### Task 8 / Step 3: Write minimal implementation

Add durable, safe observability metadata for the surface without logging secrets, raw oversized payloads, or unsafe bodies.

Prefer summarized snapshots over full raw content.

### Task 8 / Step 4: Run test to verify it passes

Run the same test again.

Expected: PASS

## Task 9: Add programmable-agent opt-in plumbing without redesigning authoring

### Task 9 Files

- Modify: `cybros/app/models/agent_program.rb`
- Modify: `cybros/app/services/agent_programs/loader.rb`
- Modify: `cybros/app/services/agent_programs/creator.rb` if bundled defaults must seed runtime-surface config
- Modify: `cybros/app/controllers/agent_programs_controller.rb` only if read surfaces need to be shown safely
- Test: `cybros/test/integration/agent_programs_test.rb`
- Test: `cybros/test/integration/system_settings_agent_programs_test.rb`

### Task 9 / Step 1: Write the failing test

Add coverage that proves:

- an agent program can opt into runtime-surface configuration
- invalid or missing config degrades to the safe no-op surface
- loading an agent program does not expose raw script internals unsafely in the wrong UI path

### Task 9 / Step 2: Run test to verify it fails

Run:

```bash
cd cybros
bin/rails test test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb
```

Expected: FAIL because agent programs do not yet carry runtime-surface wiring.

### Task 9 / Step 3: Write minimal implementation

Add only enough plumbing so runtime surfaces can be configured and loaded through the existing agent-program path.

Do not redesign:

- script authoring
- editor UX
- debugging UX
- script storage/versioning model

Those remain future work.

### Task 9 / Step 4: Run test to verify it passes

Run the same tests again.

Expected: PASS

## Task 10: Update runtime docs and run full verification

### Task 10 Files

- Modify: `cybros/docs/agent_core/behavior_spec.md`
- Modify: `cybros/docs/agent_core/public_api.md`
- Modify: `cybros/docs/agent_core/context_management.md`
- Modify: `cybros/docs/agent_core/security.md`
- Test: relevant focused test files from Tasks 1 through 9

### Task 10 / Step 1: Update docs

Document:

- the new `AgentRuntimeSurface`
- advisory-vs-authoritative merge rules
- raw vs projected tool result semantics
- context compaction moving behind the runtime surface
- programmable-agent work explicitly deferred

### Task 10 / Step 2: Run focused verification

Run the new and touched focused tests from Tasks 1 through 9.

Expected: PASS

### Task 10 / Step 3: Run broader regression verification

Run:

```bash
cd cybros
bin/rails test test/lib/agent_core test/lib/cybros test/models/conversation test/integration/agent_programs_test.rb test/integration/system_settings_agent_programs_test.rb
```

Expected: PASS

### Task 10 / Step 4: Review and finalize

Confirm the landed behavior still satisfies the core contract:

- agent sees only a runtime surface
- DAG remains hidden orchestrator truth
- static policy and sandbox ceilings remain authoritative
- context compaction and tool projection are programmable but bounded
