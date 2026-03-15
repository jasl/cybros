# Claw OpenClaw Parity Report

Date: 2026-03-15

## Scope

This report audits the accepted OpenClaw parity scope from `docs/plans/2026-03-15-claw-openclaw-loop.md` against the current Cybros implementation.

Acceptance rule for this phase:

- `claw` may own tools and prompt assembly.
- Cybros must continue to own DAG orchestration, transcript state, subagent execution, approvals, compaction, and silent finalization.
- No required capability may remain `missing`.

## Reference Set

- `references/openclaw/src/agents/tool-catalog.ts`
- `references/openclaw/src/agents/system-prompt.ts`
- `references/openclaw/src/agents/tools/memory-tool.ts`
- `references/openclaw/src/agents/tools/web-search.ts`
- `references/openclaw/src/agents/tools/web-fetch.ts`
- `references/openclaw/src/auto-reply/tokens.ts`
- `references/openclaw/docs/zh-CN/reference/session-management-compaction.md`
- `references/openclaw/src/agents/pi-embedded-runner/run.ts`
- `references/openclaw/src/agents/pi-embedded-subscribe.ts`

## Verification Matrix

All targeted verification commands completed successfully on 2026-03-15:

- `bundle exec ruby -Itest test/integration/rpc_contract_test.rb`
  - `25 runs, 161 assertions, 0 failures, 0 errors`
- `bin/rails test test/lib/agent_core/dag/prompt_assembly_test.rb`
  - `4 runs, 29 assertions, 0 failures, 0 errors`
- `bin/rails test test/integration/programmable_agent_execution_context_test.rb`
  - `2 runs, 11 assertions, 0 failures, 0 errors`
- `bin/rails test test/services/agent_rpc/lifecycle_caller_test.rb`
  - `2 runs, 10 assertions, 0 failures, 0 errors`
- `bin/rails test test/services/agent_rpc/kernel_services/conversation_memory_test.rb`
  - `2 runs, 13 assertions, 0 failures, 0 errors`
- `bin/rails test test/models/agent_rpc_operation_receipt_test.rb`
  - `2 runs, 7 assertions, 0 failures, 0 errors`
- `bin/rails test test/scenarios/dag/agent_tool_calls_flow_test.rb`
  - `5 runs, 87 assertions, 0 failures, 0 errors`
- `bin/rails test test/lib/agent_core/dag/agent_output_finalization_test.rb`
  - `7 runs, 26 assertions, 0 failures, 0 errors`
- `bin/rails test test/scenarios/dag/agent_core_context_cost_report_test.rb`
  - `4 runs, 45 assertions, 0 failures, 0 errors`

Additional DAG-level context-pressure coverage also passed:

- `bin/rails test test/lib/agent_core/dag/runtime_surface_error_handling_test.rb`
  - `10 runs, 61 assertions, 0 failures, 0 errors`

## Capability Audit

| Capability | Cybros implementation | OpenClaw references | Expected parity behavior | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| Agent-owned tool surface and `tool.execute` spine | `agents/claw/agent.yml`, `agents/claw/lib/cybros/agents/claw/application.rb`, `agents/claw/lib/cybros/agents/claw/tool_executor.rb`, `lib/cybros/programmable_agent/tool_execution.rb`, `lib/cybros/agent_runtime_resolver.rb`, `lib/cybros/agent_owned_tools.rb` | `src/agents/tool-catalog.ts` | `claw` advertises and executes its own coding, memory, and web tools through a single agent-owned catalog and RPC execution method. | matched with intentional divergence | Cybros intentionally does not move `compact_context` or subagent execution into `claw`; those remain DAG/kernel-owned to satisfy the no shadow loop rule. |
| Prompt modes for primary vs delegated execution | `agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`, `agents/claw/prompts/system.md.liquid`, `lib/cybros/programmable_agent/execution_context.rb` | `src/agents/system-prompt.ts`, `src/agents/pi-embedded-runner/run.ts`, `src/agents/pi-embedded-subscribe.ts` | Primary runs receive the full prompt surface; delegated subagent runs receive a reduced prompt that excludes full memory/bootstrap sections. | matched | Cybros uses `execution_context.execution_scope`, subagent metadata, and resolved `agent_profile` instead of OpenClaw session-key heuristics. |
| Bootstrap sections, source markers, and truncation signaling | `agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`, `agents/claw/prompts/system.md.liquid` | `src/agents/system-prompt.ts` | Prompt assembly exposes explicit Tooling, Safety, Workspace, Runtime, and Current Date/Time sections, carries source markers, enforces local bootstrap budgets, and emits truncation warnings. | matched with intentional divergence | Section naming is Cybros-specific, but the behavioral parity target is preserved: bounded bootstrap injection, explicit source provenance, and visible truncation warning. |
| Conversation memory search/get/store semantics | `app/services/agent_rpc/callback_dispatcher.rb`, `app/services/agent_rpc/kernel_services/conversation_memory.rb`, `agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb`, `test/services/agent_rpc/kernel_services/conversation_memory_test.rb` | `src/agents/tools/memory-tool.ts` | The agent can search durable memory, fetch focused snippets, and write memory through a narrow mutation path. | matched with intentional divergence | OpenClaw treats memory as workspace files. Cybros intentionally treats memory as a conversation-owned logical document behind callbacks with mutation receipts and `operation_id`. |
| Web search and fetch semantics | `agents/claw/lib/cybros/agents/claw/tools/web_provider.rb`, `agents/claw/lib/cybros/agents/claw/tools/web_tools.rb`, `agents/claw/lib/cybros/agents/claw/application.rb` | `src/agents/tools/web-search.ts`, `src/agents/tools/web-fetch.ts` | `web_search` returns structured results, `web_fetch` returns readable page content, and disabled backends are surfaced clearly. | matched with intentional divergence | Cybros currently uses a single development-usable backend, `duckduckgo_html`, plus direct fetch/parsing. OpenClaw supports a broader provider matrix and more fetch options. |
| `NO_REPLY` handling and silent finalization | `agents/claw/lib/cybros/agents/claw/hooks/before_finalize_output.rb`, `lib/cybros/programmable_agent/hook_envelope.rb`, `lib/cybros/programmable_agent/hook_action_executor.rb`, `lib/agent_core/dag/executors/agent_message_executor.rb` | `src/auto-reply/tokens.ts`, `docs/zh-CN/reference/session-management-compaction.md` | Exact `NO_REPLY` yields a successful silent turn, mixed content strips a trailing silent token, and draft output does not leak when the turn is intentionally silent. | matched with intentional divergence | OpenClaw suppresses delivery-layer output. Cybros exposes an explicit DAG-owned `finish_silently` contract and persists a `silent_finalization` marker instead of relying on hidden delivery semantics. |
| Pre-compaction memory flush | `agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb`, `lib/cybros/programmable_agent/hook_action_executor.rb`, `lib/agent_core/dag/executors/agent_message_executor.rb`, `test/lib/agent_core/dag/runtime_surface_error_handling_test.rb` | `docs/zh-CN/reference/session-management-compaction.md`, `src/agents/pi-embedded-runner/run.ts` | Before compaction, the runtime can schedule a silent memory flush and then continue through normal compaction handling. | matched with intentional divergence | OpenClaw runs a Gateway-managed silent pre-threshold flush that writes workspace memory. Cybros intentionally models this as normal DAG prepend tasks: `memory_store` first, then `compact_context`. |
| Subagent execution and minimal delegated behavior | `lib/cybros/programmable_agent/execution_context.rb`, `agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`, `agents/claw/lib/cybros/agents/claw/hooks/before_subagent_spawn.rb`, `agents/claw/lib/cybros/agents/claw/hooks/after_subagent_result.rb` | `src/agents/tool-catalog.ts`, `src/agents/pi-embedded-runner/run.ts`, `src/agents/pi-embedded-subscribe.ts` | Delegated execution is visible to the runtime as a subagent scope and uses reduced prompt/bootstrap behavior without inventing a local runner. | matched with intentional divergence | OpenClaw exposes session/subagent tools directly. Cybros keeps the canonical subagent lifecycle in the DAG engine and only lets `claw` react through hooks and prompt mode. |
| Responsibility split: Cybros owns loop, `claw` owns tooling/prompting | `agents/claw/prompts/system.md.liquid`, `lib/agent_core/dag/executors/agent_message_executor.rb`, `lib/cybros/programmable_agent/hook_envelope.rb` | `src/agents/system-prompt.ts`, `src/agents/pi-embedded-runner/run.ts`, `src/agents/pi-embedded-subscribe.ts` | The shipped system prompt and runtime surface must prevent `claw` from simulating its own scheduler, transcript, compaction loop, or silent finalization path. | matched with intentional divergence | This is the main deliberate deviation from raw OpenClaw architecture. It is required by the phase design and is the core no-shadow-loop constraint. |

## Outcome

Required line items in this phase are either:

- `matched`, or
- `matched with intentional divergence`

No required capability remains `missing`.

## Accepted Divergences

The following divergences are intentional and required for this phase:

1. Memory is conversation-owned state, not a workspace-file source of truth.
2. Subagent execution stays on the Cybros DAG spine instead of `claw`-local session orchestration.
3. Silent completion is modeled as an explicit Cybros runtime contract (`finish_silently`) instead of hidden delivery suppression alone.
4. Web search/fetch uses a narrower development-ready backend set than upstream OpenClaw.

These divergences preserve the accepted user-visible behavior while enforcing the no shadow loop rule.
