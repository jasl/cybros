# DAG Debug CLI Design

## Summary

The current retry diagnostics are split across two ad-hoc scripts:

- `script/debug_retry_llm_request.rb`
- `script/diagnose_retry_400.rb`

They were useful for one-off debugging, but they are too narrow, too stateful, and too hard to reuse for the broader class of failures we are now hitting:

- retry/action policy failures
- compressed or historical retry attempts
- context assembly mismatches
- malformed provider payloads
- live provider errors that move from one wire-level validation failure to the next
- successful executions that still produce empty or malformed assistant output

We need one coherent debugging entry point that can inspect DAG state, trace retry chains, capture the final LLM payload, and run a real provider smoke flow.

## Goals

- Replace narrow “retry 400” diagnostics with a general DAG/provider debug entry point.
- Support both historical inspection and live execution capture.
- Keep the CLI thin and move the real logic into testable Ruby helpers.
- Make the tooling useful for both manual debugging and future regression tests.

## Non-goals

- This is not a user-facing admin feature.
- This does not attempt to bypass retry limits or mutate production data unsafely.
- This does not solve every possible Responses tool-loop persistence issue in the first pass.

## Chosen shape

Use a single script:

- `script/dag_debug.rb`

with focused subcommands:

- `inspect <node_id>`
  - print node basics, retry chain, graph relationships, compression state, and action eligibility context
- `context <node_id>`
  - show `context_for_full`, `context_closure_for_full`, and the final prompt build shape (`system_prompt`, messages, tools, options)
- `capture <node_id>`
  - wrap the resolved provider and capture the final wire payload, request options, provider metadata, and stream/result summary
- `retry <node_id>`
  - run the real retry flow through `Conversation#retry_agent_node!` and inline jobs, then report the created node/result
- `smoke`
  - create a temporary conversation and run a real provider call using a supplied `conversation_id`, `model_ref`, and `prompt`

## Architecture

### CLI layer

`script/dag_debug.rb` should only:

- parse subcommands/options
- call helper objects
- format human-readable or JSON output
- return non-zero exit codes for invalid usage or failed live runs

### Helper layer

Introduce a reusable CLI-scoped diagnostics namespace:

- runner-facing implementation: `lib/cybros/cli/dag_debug.rb`

This helper should expose small, testable entry points:

- inspect a node/retry chain
- assemble context/prompt snapshots
- capture provider request/response metadata
- run retry inline
- run live smoke conversations inline

### Capture model

The capture path should wrap the provider in-process and record:

- final prompt shape as seen by `runtime.provider.chat`
- final Responses/Chat payload inputs (`instructions`, `input`, `tools`, options)
- provider metadata (`last_call_metadata`)
- stream result summary (`done`, `error`, `tool_calls`, output text length)

This directly covers the bugs we already found:

- missing `instructions`
- missing `store: false`
- wrong `reasoning_effort` mapping
- future empty-output debugging

## Output modes

Support both:

- human-readable default output for local debugging
- `--json` for piping into future tests or tooling

The JSON shape should be stable enough to assert against in tests, even if the pretty output evolves.

## Old scripts

`script/diagnose_retry_400.rb` should be removed.

`script/debug_retry_llm_request.rb` should either:

- be removed outright, or
- become a tiny compatibility wrapper that prints a deprecation notice and forwards to `script/dag_debug.rb capture ...`

The default recommendation is to keep at most one temporary wrapper during migration and otherwise consolidate on the new CLI.

## Testing strategy

### Unit / helper tests

Add focused tests for the helper layer, including:

- inspect output on retry chains with compressed ancestors
- context snapshot generation for active vs compressed nodes
- capture output for system prompt lifting and Responses request normalization
- retry inline result reporting

### Existing regression coverage

Keep the existing provider regressions green:

- `instructions` must be top-level for Responses
- `store` must default to `false`
- `reasoning_effort` must map to `reasoning.effort`

### Smoke-level verification

Manual verification should still include a real inline provider smoke run after script changes land, because the CLI’s value depends on matching production behavior closely.
