# Model Eval Harness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a Cybros-native `eval` harness that lives under `Cybros::CLI`, supports deterministic regression suites plus live provider smoke suites, and writes durable reports that can be rerun after model or provider updates.

**Architecture:** Keep the user-facing entrypoint as a thin `script/eval` wrapper and put the main orchestration in `Cybros::CLI`. Tier A should run deterministic regression cases using stable fixtures/mocks and current DAG/runtime plumbing. Tier B should run real-provider smoke cases against all enabled models from `config/llm/providers.yml` by default, with optional filters for narrower runs. Tier C should be documented as future work only and must not be implemented in this plan.

**Tech Stack:** Ruby 4.0, Rails 8 alpha, ActiveSupport tests, `Conversation` facade, DAG engine (`DAG::Runner`, `DAG::Scheduler`, `AgentCore::DAG::Session`), `Cybros::AgentRuntimeResolver`, `Cybros::CLI::DAGDebug`, `config/llm/providers.yml`, filesystem report output under `tmp/`.

## Scope boundary

This plan implements:

- Tier A deterministic regression harness
- Tier B live provider smoke harness
- catalog-driven model selection and filters
- report writing and summaries
- failure capture integration for live runs

This plan explicitly does **not** implement:

- Tier C LLM-as-judge evaluation
- dashboards, scheduling, or hosted result storage
- broad statistical sampling-profile matrices from the legacy harness

## Execution order and dependency constraints

Recommended order:

1. Task 1 (`CLI skeleton`)
2. Task 2 (`model selection from catalog`)
3. Task 3 (`report schema and writer`)
4. Task 4 (`Tier A case registry and deterministic runner`)
5. Task 5 (`Tier B live smoke runner`)
6. Task 6 (`failure capture integration`)
7. Task 7 (`initial suite definitions`)
8. Task 8 (`final verification and usage docs`)

Hard dependencies:

- Task 1 must land before everything else.
- Task 2 must land before Tasks 5 and 7 because Tier B defaults to the catalog model matrix.
- Task 3 must land before Tasks 4, 5, and 6 because all runs must emit one report schema.
- Task 4 should land before Task 5 so the harness has a stable local regression layer first.
- Task 5 must land before Task 6 because failure capture hangs off the live runner.
- Task 7 should land after Tasks 4 and 5 because the suite files should target already-implemented runner behavior.

---

## Task 1: Add the `Cybros::CLI::Eval` skeleton and thin `script/eval` entrypoint

### Task 1 Files

- Create: `lib/cybros/cli/eval.rb`
- Create: `script/eval`
- Test: `test/lib/cybros/cli/eval_test.rb`

### Task 1 / Step 1: Write the failing test

Add CLI-level tests that assert:

- `Cybros::CLI::Eval.run(["list", "models"])` is callable
- `Cybros::CLI::Eval.run(["list", "suites"])` is callable
- `Cybros::CLI::Eval.run(["run", ...])` rejects invalid usage with stable errors
- `script/eval` can delegate into the CLI

### Task 1 / Step 2: Run test to verify it fails

Run: `bin/rails test test/lib/cybros/cli/eval_test.rb`

Expected: FAIL because no eval CLI exists yet.

### Task 1 / Step 3: Write minimal implementation

Implement:

- `Cybros::CLI::Eval`
- subcommands:
  - `list models`
  - `list suites`
  - `run`
  - `summarize`
- thin `script/eval` wrapper that boots Rails and forwards into the CLI

Do not implement full runner logic yet; stub/structure is enough for this task.

### Task 1 / Step 4: Run test to verify it passes

Run: `bin/rails test test/lib/cybros/cli/eval_test.rb`

Expected: PASS

## Task 2: Add catalog-driven model selection and filters

### Task 2 Files

- Create: `lib/cybros/cli/eval/model_selector.rb`
- Modify: `lib/cybros/cli/eval.rb`
- Test: `test/lib/cybros/cli/eval/model_selector_test.rb`

### Task 2 / Step 1: Write the failing test

Add tests that prove:

- Tier B default selection includes all enabled models from `config/llm/providers.yml` for the current environment
- required-credential models without credentials are returned as `skipped`, not silently dropped
- filters work:
  - `--provider`
  - `--model-ref`
  - `--tier`
  - `--suite`
  - `--case`

### Task 2 / Step 2: Run test to verify it fails

Run: `bin/rails test test/lib/cybros/cli/eval/model_selector_test.rb`

Expected: FAIL because no selector exists yet.

### Task 2 / Step 3: Write minimal implementation

Implement selector logic that derives the matrix from:

- `Cybros::LLM::Catalog`
- `config/llm/providers.yml`
- current environment
- `LLMProvider` credential presence

Make sure the selector returns explicit skip reasons for non-runnable models.

### Task 2 / Step 4: Run test to verify it passes

Run: `bin/rails test test/lib/cybros/cli/eval/model_selector_test.rb`

Expected: PASS

## Task 3: Add a durable report schema and summary writer

### Task 3 Files

- Create: `lib/cybros/cli/eval/reporter.rb`
- Create: `lib/cybros/cli/eval/result.rb`
- Modify: `lib/cybros/cli/eval.rb`
- Test: `test/lib/cybros/cli/eval/reporter_test.rb`

### Task 3 / Step 1: Write the failing test

Add tests that assert a run creates:

- `manifest.json`
- `runs.jsonl`
- `summary.json`
- `summary_by_model.json`
- `summary_by_suite.json`
- `summary_by_case.json`

and that per-run records include:

- tier
- suite
- case id
- provider/model identifiers
- status
- latency
- usage
- assertion results

### Task 3 / Step 2: Run test to verify it fails

Run: `bin/rails test test/lib/cybros/cli/eval/reporter_test.rb`

Expected: FAIL because the reporter does not exist.

### Task 3 / Step 3: Write minimal implementation

Implement a simple report writer under `tmp/eval_reports/<timestamp>/`.

Keep the schema JSON-friendly and diff-friendly.

Do not add historical comparison or dashboards in this task.

### Task 3 / Step 4: Run test to verify it passes

Run: `bin/rails test test/lib/cybros/cli/eval/reporter_test.rb`

Expected: PASS

## Task 4: Implement Tier A deterministic regression execution

### Task 4 Files

- Create: `lib/cybros/cli/eval/case_registry.rb`
- Create: `lib/cybros/cli/eval/deterministic_runner.rb`
- Create: `lib/cybros/cli/eval/assertions.rb`
- Create: `config/eval/suites/tier_a.yml`
- Test: `test/lib/cybros/cli/eval/deterministic_runner_test.rb`

### Task 4 / Step 1: Write the failing test

Add deterministic-runner tests that prove the harness can execute local stable cases such as:

- non-empty final text
- single tool call
- tool-result -> final answer
- retry path stays valid
- request-shape regressions stay covered

These tests should not depend on live provider credentials.

### Task 4 / Step 2: Run test to verify it fails

Run: `bin/rails test test/lib/cybros/cli/eval/deterministic_runner_test.rb`

Expected: FAIL because no deterministic runner or case registry exists.

### Task 4 / Step 3: Write minimal implementation

Implement:

- declarative Tier A suite loading from `config/eval/suites/tier_a.yml`
- reusable assertion kinds
- deterministic execution using existing mock/stub paths and current DAG/runtime plumbing

Prefer current Cybros seams over inventing a second evaluation engine.

### Task 4 / Step 4: Run test to verify it passes

Run: `bin/rails test test/lib/cybros/cli/eval/deterministic_runner_test.rb`

Expected: PASS

## Task 5: Implement Tier B live provider smoke execution

### Task 5 Files

- Create: `lib/cybros/cli/eval/live_runner.rb`
- Create: `config/eval/suites/tier_b.yml`
- Modify: `lib/cybros/cli/eval.rb`
- Reuse: `lib/cybros/cli/dag_debug.rb`
- Test: `test/lib/cybros/cli/eval/live_runner_test.rb`

### Task 5 / Step 1: Write the failing test

Add live-runner tests that assert:

- the runner can build a matrix from the selector
- text smoke and tool smoke cases are capability-gated
- non-runnable models are marked skipped
- run records include conversation/node identifiers for executed cases

Keep tests credential-free by stubbing execution seams where needed.

### Task 5 / Step 2: Run test to verify it fails

Run: `bin/rails test test/lib/cybros/cli/eval/live_runner_test.rb`

Expected: FAIL because no live runner exists.

### Task 5 / Step 3: Write minimal implementation

Implement live execution that:

- uses `Conversation#append_user_message!`
- runs with inline jobs or equivalent bounded sync orchestration
- supports the default “all enabled models” Tier B sweep
- supports narrowing to one provider/model/case

The initial Tier B suite should include:

- `live_text_smoke`
- `live_tool_smoke`

### Task 5 / Step 4: Run test to verify it passes

Run: `bin/rails test test/lib/cybros/cli/eval/live_runner_test.rb`

Expected: PASS

## Task 6: Integrate bounded failure capture for live runs

### Task 6 Files

- Modify: `lib/cybros/cli/eval/live_runner.rb`
- Modify: `lib/cybros/cli/eval/reporter.rb`
- Reuse: `lib/cybros/cli/dag_debug.rb`
- Test: `test/lib/cybros/cli/eval/live_runner_test.rb`

### Task 6 / Step 1: Write the failing test

Add tests that assert:

- when a live case fails, the runner can optionally trigger bounded capture
- the run record includes a `failure_capture_path`
- capture is opt-in (for example `--capture-failures`) so normal runs do not always double cost

### Task 6 / Step 2: Run test to verify it fails

Run the live runner tests again.

Expected: FAIL because no failure-capture plumbing exists.

### Task 6 / Step 3: Write minimal implementation

Integrate the existing `dag_debug capture` machinery as a post-failure artifact step.

Keep this bounded:

- do not recursively re-run broad eval matrices
- do not auto-capture on skip statuses
- do not force capture for Tier A

### Task 6 / Step 4: Run test to verify it passes

Run: `bin/rails test test/lib/cybros/cli/eval/live_runner_test.rb`

Expected: PASS

## Task 7: Seed the first real suite definitions

### Task 7 Files

- Modify/Create: `config/eval/suites/tier_a.yml`
- Modify/Create: `config/eval/suites/tier_b.yml`
- Test: `test/lib/cybros/cli/eval/case_registry_test.rb`

### Task 7 / Step 1: Write the failing test

Add tests that assert the initial suite files load and contain at least:

- Tier A:
  - basic text regression
  - tool-call regression
  - retry/tool-loop regression
- Tier B:
  - live text smoke
  - live tool smoke

### Task 7 / Step 2: Run test to verify it fails

Run: `bin/rails test test/lib/cybros/cli/eval/case_registry_test.rb`

Expected: FAIL because the initial suite files or registry wiring are incomplete.

### Task 7 / Step 3: Write minimal implementation

Seed an intentionally small but high-value initial suite set.

Do not attempt to port the full legacy matrix yet.

### Task 7 / Step 4: Run test to verify it passes

Run: `bin/rails test test/lib/cybros/cli/eval/case_registry_test.rb`

Expected: PASS

## Task 8: Add final CLI verification and usage documentation

### Task 8 Files

- Modify: `script/eval`
- Modify: `lib/cybros/cli/eval.rb`
- Modify: any README or internal docs that should mention the new harness
- Test: `test/lib/cybros/cli/eval_test.rb`

### Task 8 / Step 1: Write the failing test

Add or extend CLI tests for commands like:

- `script/eval list models`
- `script/eval list suites`
- `script/eval run --tier A`
- `script/eval run --tier B --provider openrouter`
- `script/eval run --tier B --model-ref openrouter/openai-gpt-5.4`
- `script/eval summarize <report_dir>`

### Task 8 / Step 2: Run test to verify it fails

Run the CLI test file again.

Expected: FAIL until the command surface is finalized.

### Task 8 / Step 3: Write minimal implementation

Finalize:

- usage/help text
- stable command surface
- short documentation describing Tier A vs Tier B
- explicit note that Tier C is future work only

### Task 8 / Step 4: Run test to verify it passes

Run: `bin/rails test test/lib/cybros/cli/eval_test.rb`

Expected: PASS

## Final verification

### Final verification files

- Verify: `lib/cybros/cli/eval.rb`
- Verify: `lib/cybros/cli/eval/model_selector.rb`
- Verify: `lib/cybros/cli/eval/case_registry.rb`
- Verify: `lib/cybros/cli/eval/deterministic_runner.rb`
- Verify: `lib/cybros/cli/eval/live_runner.rb`
- Verify: `lib/cybros/cli/eval/reporter.rb`
- Verify: `lib/cybros/cli/eval/assertions.rb`
- Verify: `script/eval`
- Verify: `config/eval/suites/tier_a.yml`
- Verify: `config/eval/suites/tier_b.yml`

### Final verification steps

Run:

- `bin/rails test test/lib/cybros/cli/eval_test.rb`
- `bin/rails test test/lib/cybros/cli/eval/model_selector_test.rb`
- `bin/rails test test/lib/cybros/cli/eval/reporter_test.rb`
- `bin/rails test test/lib/cybros/cli/eval/deterministic_runner_test.rb`
- `bin/rails test test/lib/cybros/cli/eval/live_runner_test.rb`
- `bin/rails test test/lib/cybros/cli/eval/case_registry_test.rb`

Manual verification:

- run Tier A locally
- run Tier B against one model
- run Tier B against one provider
- run Tier B with no filter and confirm the report includes all enabled current-environment models, including explicit skip rows where credentials or environment gating prevent execution

## Future work (not in this plan)

The following are intentionally excluded from this implementation plan and should be discussed after v1 lands:

- Tier C LLM-as-judge evaluation
- pairwise ranking or subjective answer scoring
- workspace/artifact/trajectory judging
- dashboards and historical trend analysis
- scheduled hosted evaluation jobs
