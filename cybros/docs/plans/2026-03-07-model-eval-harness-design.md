# Model Eval Harness Design

## Summary

This design defines a Cybros-native `eval` harness for comparing and re-checking models over time.

The target shape is:

- the main orchestration lives under `Cybros::CLI`
- `script/eval` is only a thin entrypoint
- Tier A provides deterministic regression suites that are stable in local development and CI
- Tier B provides real-provider smoke coverage over the current model catalog
- Tier C is explicitly recorded as future work, not part of the first implementation
- the default product truth for tool reliability remains runtime statistics on `/statistics`, not eval output
- eval may reuse the runtime failure taxonomy later, but eval/debug samples are not part of default product metrics

The goal is not to build a research lab in one step. The goal is to make model updates, provider changes, and catalog refreshes auditable, repeatable, and comparable inside the Cybros repo.

## Goals

- Add a first-class `eval` entrypoint under `Cybros::CLI`.
- Reuse Cybros’ existing provider catalog instead of creating a second model registry.
- Make it easy to rerun evaluations after model updates or provider changes.
- Keep deterministic regression suites separate from live provider smoke runs.
- Default Tier B to attempt all enabled models from `config/llm/providers.yml` for the current environment.
- Allow filtering by provider, model, tier, suite, and case so evaluation runs can be narrowed when needed.
- Produce durable structured reports that can be compared across runs.
- Reuse current DAG/runtime/provider abstractions rather than introducing a parallel execution stack.
- Keep eval outputs separate from the default runtime-only product statistics surface.

## Non-goals

- Build judge-based or preference-based scoring into the first version.
- Replace existing unit, integration, or scenario tests.
- Turn the first version into a permanent scheduled service or UI dashboard.
- Support every possible experimental matrix dimension from the legacy harness on day one.
- Introduce a second hand-maintained model list outside `config/llm/providers.yml`.
- Feed eval/debug samples into the default `/statistics` runtime dataset.

## Existing Context

Two prior evaluation directions exist in the references:

1. `references/vibe_tavern/script/eval`
   - Ruby-based
   - deterministic assertion-heavy scenario runs
   - OpenRouter-oriented model matrices
   - strong fit for “does this model/provider still behave correctly?”

2. `references/agent-as-a-judge`
   - separate Python research-style project
   - LLM-as-judge / artifact scoring orientation
   - better fit for later subjective quality scoring, not for v1

Inside Cybros, the strongest reusable seams already exist:

- `lib/cybros/agent_runtime_resolver.rb`
- `config/llm/providers.yml`
- `app/models/llm_provider.rb`
- `app/models/conversation.rb`
- `lib/dag/runner.rb`
- `lib/agent_core/dag/session.rb`
- `lib/cybros/cli/dag_debug.rb`
- `script/dag_debug.rb`
- `test/scenarios/dag`

That means we do not need to port the legacy harness literally. We can build a Cybros-native harness that borrows its structure and reporting ideas while using our current runtime stack.

## Approaches Considered

### Approach A: Directly port the legacy Ruby eval scripts

Pros:

- fastest way to get something runnable
- closest to the prior `vibe_tavern` workflow

Cons:

- duplicates model selection logic that Cybros already owns in `providers.yml`
- preserves old OpenRouter- and VibeTavern-specific assumptions
- keeps the harness outside the Cybros execution model instead of integrating with it

### Approach B: Test-only evals inside `test/scenarios/dag`

Pros:

- very stable
- naturally CI-friendly
- excellent for regression assertions

Cons:

- weak ergonomics for ad hoc model sweeps
- poor reporting for “try all models in the catalog”
- not a good substitute for a user-invoked evaluation CLI

### Approach C: CLI-first Cybros-native harness

Pros:

- fits the user-facing `@eval` workflow naturally
- can reuse Cybros runtime resolution, conversation execution, and debug capture
- can support both deterministic and live suites
- can produce explicit report directories and summaries

Cons:

- requires a bit more design work up front
- needs explicit suite/case/report abstractions

## Chosen Direction

Choose **Approach C**, while continuing to use scenario tests as the place where many deterministic cases are proven and maintained.

Concretely:

- orchestration lives in `Cybros::CLI`
- deterministic and live evaluation share one report schema
- Tier A is the default safe regression layer
- Tier B is the explicit live model/provider layer
- Tier C is documented as future work and intentionally excluded from v1 implementation

## Decision 1: Keep the primary logic under `Cybros::CLI`

The main orchestration should live in the existing CLI namespace:

- `lib/cybros/cli/eval.rb`

Supporting code should stay nearby, for example:

- `lib/cybros/cli/eval/model_selector.rb`
- `lib/cybros/cli/eval/case_registry.rb`
- `lib/cybros/cli/eval/runner.rb`
- `lib/cybros/cli/eval/reporter.rb`
- `lib/cybros/cli/eval/assertions.rb`

The shell entrypoint should remain thin:

- `script/eval`

Why:

- it matches the user’s expectation of an `@eval` command
- it keeps the operational logic in the same place as `Cybros::CLI::DAGDebug`
- it avoids the old “script as business logic” anti-pattern

## Decision 2: Use the current Cybros catalog as the model source of truth

The evaluation harness should not carry its own hand-maintained model list.

Instead, it should derive its Tier B model matrix from:

- `config/llm/providers.yml`
- `Cybros::LLM::Catalog`
- current environment gating
- current credential presence in `LLMProvider`

### Tier B default model set

Tier B should, by default, attempt **all enabled models in `providers.yml` for the current environment**.

That means:

- enabled `openai` models
- enabled `codex_subscription` models
- enabled `openrouter` models
- enabled `dev` models when the environment permits them

Models that cannot run should still be visible in the report and marked as:

- `skipped_missing_credential`
- `skipped_environment_not_enabled`
- `skipped_capability_mismatch`

They should not silently disappear from the matrix.

### Narrowing the run

The CLI should support targeted selection, such as:

- `--provider openrouter`
- `--model-ref openrouter/openai-gpt-5.4-pro`
- `--tier B`
- `--suite live_tool_smoke`
- `--case single_tool_call`

This gives us the “run all models” default while still supporting cheap spot-checks.

## Decision 3: Tiered evaluation model

The harness should be explicitly tiered.

### Tier A: Deterministic regression

Purpose:

- catch Cybros runtime, DAG, tool-loop, and provider-normalization regressions
- remain stable enough for local reruns and CI

Characteristics:

- uses mock or fixture-backed execution where practical
- assertions are deterministic and code-based
- failures indicate a product/runtime contract break, not model taste

Initial suite categories:

- text output baseline
- tool-calling baseline
- streamed/non-streamed provider fallback handling
- retry / rerun / interrupted-output safety
- request-shape regressions (`instructions`, `store`, `reasoning`, tool schema)

### Tier B: Live provider smoke

Purpose:

- detect model/provider regressions after catalog updates
- confirm that real providers still produce acceptable results under Cybros’ runtime

Characteristics:

- uses real credentials and network
- runs fewer but more representative cases
- costlier and somewhat more variable than Tier A
- should be user-invoked, not run constantly

Initial suite categories:

- `live_text_smoke`
- `live_tool_smoke`
- optional `live_retry_smoke`

### Tier C: Future work

Tier C should be recorded now but not implemented in v1.

Future directions:

- LLM-as-judge scoring
- pairwise model comparisons
- workspace/artifact/trajectory review
- rubric-based quality scoring for longer answers
- longitudinal score tracking and dashboards

Tier C should only be discussed after Tier A and Tier B are stable enough to trust their raw execution outputs and artifacts.

## Relationship To Runtime Statistics

The eval harness complements runtime statistics, but it does not replace them.

The canonical product-facing reliability view is now:

- durable fact rows in `Statistics::ToolCallFact`
- product aggregations under `Cybros::Statistics::*`
- the default `/statistics` page filtered to `sample_origin = "runtime"`

That is the real-world truth for tool reliability because it reflects actual user traffic, actual approval paths, actual retries, and real dependency failures.

Eval remains a curated comparison tool:

- its outputs live in report directories under `tmp/`
- it may reuse the same failure taxonomy later for comparability
- any future fact writes from eval must be explicitly tagged `sample_origin = "eval"`
- eval/debug samples must stay out of the default product metrics unless a caller explicitly asks for them

## Decision 4: Execution should reuse the current Cybros runtime path

The evaluation harness should not bypass the Cybros execution model unless a case explicitly needs lower-level provider probing.

Primary execution path:

- resolve `model_ref` through `Cybros::AgentRuntimeResolver`
- create a real `Conversation`
- use `Conversation#append_user_message!`
- drive execution with inline jobs or equivalent sync orchestration
- inspect final nodes / graph / usage / errors

Why:

- this catches DAG-level bugs, not just provider bugs
- it reflects how the product actually runs
- it lets eval cases reuse `dag_debug` capture paths when a case fails

### Lower-level capture path

When a case needs request/response introspection:

- reuse `Cybros::CLI::DAGDebug.capture_node`

This should remain a secondary debugging path, not the default way all evals are executed.

## Decision 5: Case definitions should be declarative-first, assertion-backed

The old harness hardcoded everything in Ruby. For Cybros, a hybrid is cleaner:

- declarative suite/case metadata for matrix construction
- code-backed assertion kinds for non-trivial checks

Recommended case storage:

- `config/eval/suites/*.yml`

Recommended assertion implementation:

- `lib/cybros/cli/eval/assertions.rb`
- optional submodules under `lib/cybros/cli/eval/assertions/`

### Example case shape

```yaml
suite: live_tool_smoke
tier: B
description: Verify one real tool call round-trip per model.

cases:
  - id: single_memory_search
    prompt: >
      Call the memory_search tool exactly once with query "eval smoke".
      After the tool result, answer with exactly DONE.
    requires:
      tools: true
    assertions:
      - kind: final_state_finished
      - kind: exactly_one_task
      - kind: final_text_equals
        expected: DONE
```

This keeps matrix definition human-readable without forcing every assertion into YAML.

## Decision 6: Report format should be durable and diff-friendly

Each eval run should create a timestamped report directory, for example:

- `tmp/eval_reports/<timestamp>/`

Recommended files:

- `manifest.json`
- `runs.jsonl`
- `summary.json`
- `summary_by_model.json`
- `summary_by_suite.json`
- `summary_by_case.json`
- `failures.json`

Optional artifacts:

- `artifacts/<run_id>.json`
- captured `dag_debug` payloads for failures

### Per-run fields

At minimum, each run record should include:

- `tier`
- `suite`
- `case_id`
- `provider_key`
- `model_ref`
- `api_model`
- `status`
- `latency_ms`
- `usage`
- `assertion_results`
- `conversation_id`
- `dag_node_id`
- optional `failure_capture_path`

### Status classes

Recommended statuses:

- `passed`
- `failed`
- `errored`
- `skipped_missing_credential`
- `skipped_environment_not_enabled`
- `skipped_capability_mismatch`

## Decision 7: Live failures should automatically point to capture artifacts

Tier B failures are most useful when they are debuggable immediately.

Recommended behavior:

- when a live case fails, optionally run a bounded `dag_debug capture` step
- store the capture artifact path in the run record
- do not always capture by default if it would double cost or side effects
- allow a flag such as `--capture-failures`

This makes Tier B much more useful after model or provider changes.

## Decision 8: The first implementation should keep the matrix intentionally smaller than the legacy harness

The old `vibe_tavern` matrix had more axes:

- models
- sampling profiles
- strategies
- language policies
- scenarios
- trials

For Cybros v1, we should intentionally start smaller:

- tiers
- suites
- cases
- model refs
- optional trials

Why:

- Cybros already has provider defaults in `providers.yml`
- we do not yet need the full old sampling-profile system
- the first value comes from repeatable product-level regressions, not maximum matrix breadth

We can add more dimensions later if a real need appears.

## Future Work (Tier C)

Tier C should be recorded as future work only.

Potential future additions:

- judge-based answer quality scoring
- trajectory scoring for tool reasoning quality
- artifact/workspace review for coding tasks
- pairwise model ranking
- historical report comparison and trend dashboards
- scheduled nightly or pre-release live evaluation jobs

Tier C should not block Tier A or Tier B implementation.

## Recommended V1 Success Criteria

The v1 harness should be considered successful when:

- `script/eval` exists and is usable locally
- Tier A deterministic suites run reproducibly
- Tier B can run all enabled catalog models by default
- Tier B can also be narrowed to one provider or one model
- reports are written durably to `tmp/eval_reports`
- live failures can be debugged with capture artifacts
- updating `providers.yml` or switching provider credentials no longer requires ad hoc smoke scripts to understand regressions
