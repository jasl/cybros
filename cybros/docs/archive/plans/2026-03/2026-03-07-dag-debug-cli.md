# DAG Debug CLI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the two narrow retry diagnostics scripts with one testable DAG/provider debug CLI that can inspect graph state, capture final LLM payloads, run real retries inline, and execute provider smoke checks.

**Architecture:** Add a CLI-scoped runner-only implementation under `lib/cybros/cli/`, then keep `script/dag_debug.rb` as a thin argument-parsing and formatting layer. Retain regression coverage for Responses request construction while adding helper-focused tests for DAG inspection and live debug flows.

**Tech Stack:** Ruby 4.0, Rails 8 alpha, ActiveSupport tests, DAG engine (`Conversation`, `DAG::Graph`, `DAG::Runner`), AgentCore provider/runtime abstraction.

---

### Task 1: Add a helper layer for DAG inspection and provider capture

**Files:**
- Create: `lib/cybros/cli/dag_debug.rb`
- Test: `test/lib/cybros/debug/dag_debug_test.rb`

**Step 1: Write the failing test**

Add helper tests that assert:

- `inspect_node(node_id)` returns node basics, retry chain info, and edge summaries
- `context_snapshot(node_id)` returns `context_for_full`, `context_closure_for_full`, and final built prompt pieces
- `capture_node(node_id, execute: false)` reports final model/messages/tools/options for a wrapped provider call

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/debug/dag_debug_test.rb`

Expected: FAIL because the helper does not exist yet.

**Step 3: Write minimal implementation**

Implement a small helper object/module with methods for:

- node lookup + retry chain lookup
- context/prompt build snapshots
- provider wrapping and request capture
- result normalization into stable hashes

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/debug/dag_debug_test.rb`

Expected: PASS

### Task 2: Add the unified CLI

**Files:**
- Create: `script/dag_debug.rb`
- Modify: `lib/cybros/cli/dag_debug.rb`
- Test: `test/lib/cybros/debug/dag_debug_test.rb`

**Step 1: Write the failing test**

Add helper-level expectations that mirror the intended CLI subcommands:

- `inspect`
- `context`
- `capture`
- `retry`
- `smoke`

The tests should verify the returned hashes needed for rendering and JSON output.

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/debug/dag_debug_test.rb`

Expected: FAIL because the subcommand methods are missing.

**Step 3: Write minimal implementation**

Implement:

- command parsing in `script/dag_debug.rb`
- shared formatter helpers for default text output and `--json`
- inline retry/smoke execution support through `ActiveJob::Base.queue_adapter = :inline` in bounded scopes

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/debug/dag_debug_test.rb`

Expected: PASS

### Task 3: Fold in the existing retry/debug workflows

**Files:**
- Modify: `script/debug_retry_llm_request.rb`
- Delete: `script/diagnose_retry_400.rb`
- Modify: `script/dag_debug.rb`
- Test: `test/lib/cybros/debug/dag_debug_test.rb`

**Step 1: Write the failing test**

Add coverage for:

- capture output that includes Responses `instructions`, `store`, and `reasoning` fields
- retry inline output that reports created node id, final state, and provider error body

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/cybros/debug/dag_debug_test.rb test/lib/agent_core/resources/provider/simple_inference_provider_responses_test.rb`

Expected: FAIL until the compatibility/migration behavior is implemented.

**Step 3: Write minimal implementation**

Choose one migration path:

- convert `script/debug_retry_llm_request.rb` into a forwarding wrapper to `dag_debug capture`
- remove `script/diagnose_retry_400.rb`

Keep only one canonical path for retry/provider diagnostics.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/cybros/debug/dag_debug_test.rb test/lib/agent_core/resources/provider/simple_inference_provider_responses_test.rb`

Expected: PASS

### Task 4: Verify real live flows still work

**Files:**
- Modify: `script/dag_debug.rb` (if needed)
- Test: `test/lib/agent_core/resources/provider/simple_inference_provider_responses_test.rb`
- Test: `test/lib/agent_core/resources/provider/simple_inference_provider_test.rb`

**Step 1: Write the failing test**

If a helper path is still missing coverage for:

- `store: false`
- `reasoning_effort -> reasoning.effort`
- Responses tool schema

extend `test/lib/agent_core/resources/provider/simple_inference_provider_responses_test.rb` first.

**Step 2: Run test to verify it fails**

Run the specific provider test you added.

Expected: FAIL until implementation matches the live Codex backend.

**Step 3: Write minimal implementation**

Make the smallest provider/helper change required to keep live Codex requests valid.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/agent_core/resources/provider/simple_inference_provider_responses_test.rb test/lib/agent_core/resources/provider/simple_inference_provider_test.rb`

Expected: PASS

**Step 5: Manual smoke verification**

Run a real inline smoke flow against the configured `codex_subscription/gpt-5.4` provider:

Run: `bin/rails runner '...'`

Expected:

- node reaches `finished` or a meaningful non-400 failure
- no `provider_error_body` validation complaints for `instructions`, `store`, or `reasoning_effort`

### Task 5: Final verification

**Files:**
- Verify: `lib/cybros/cli/dag_debug.rb`
- Verify: `script/dag_debug.rb`
- Verify: `script/debug_retry_llm_request.rb`
- Verify: `script/diagnose_retry_400.rb`
- Verify: `test/lib/cybros/debug/dag_debug_test.rb`
- Verify: `test/lib/agent_core/resources/provider/simple_inference_provider_responses_test.rb`
- Verify: `test/lib/agent_core/resources/provider/simple_inference_provider_test.rb`

**Step 1: Run focused verification**

Run:

- `bin/rails test test/lib/cybros/debug/dag_debug_test.rb`
- `bin/rails test test/lib/agent_core/resources/provider/simple_inference_provider_responses_test.rb`
- `bin/rails test test/lib/agent_core/resources/provider/simple_inference_provider_test.rb`

**Step 2: Check lint diagnostics**

Run `ReadLints` for the changed files and fix any newly introduced issues.

**Step 3: Manual CLI sanity checks**

Run:

- `bin/rails runner script/dag_debug.rb inspect <node_id>`
- `bin/rails runner script/dag_debug.rb context <node_id>`
- `bin/rails runner script/dag_debug.rb capture <node_id>`

Expected: readable output and stable JSON mode.
