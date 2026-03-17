# Cybros / Claw Kernel Program Architecture Audit

## Executive Summary

The most serious current boundary error is not that `claw` owns tools or prompt text. It is that durable runtime semantics are still split across the kernel and the program. `memory` is the clearest case: `claw` still decides when to flush memory before compaction and still exposes the tool surface, while `cybros` already owns the actual mutation path and writes the real documents. That is kernel authority leaking through a program hook.

Top migration candidates to evaluate immediately:

- move durable memory semantics and pre-compaction flush policy into `cybros`
- move bootstrap authority tasks (`cybros_seed_message`, title generation, lane summary scheduling) into `cybros`
- collapse duplicated workspace bootstrap to one bounded implementation

Highest-confidence delete-now items:

- delete the legacy `execution_target.list` / `planning.execution_target_proposal` branch from bundled `claw`
- remove fixture-only scenario mutations from the shipped `before_agent_step` hook
- archive active plan docs that still present `AgentProgram` / `ExecutionTarget` era nouns as live design

Recommended path: phased, not big-bang.

Reason: targeted verification passed, current product-facing docs already largely reflect the newer boundary, and the drift is concentrated in a manageable set of kernel/program seams plus compatibility leftovers. A destructive cutover is possible, but it is not required to get the architecture back under control.

## Scope And Evidence

This audit treats `cybros` as the kernel/runtime and bundled `agents/claw` as the program loaded into that runtime.

Accepted boundary inputs reviewed before code inspection:

- `cybros/docs/plans/2026-03-17-cybros-claw-kernel-program-audit-design.md`
- `cybros/docs/plans/2026-03-13-conversation-agent-runtime-simplification-design.md`
- `cybros/docs/plans/2026-03-16-bundled-claw-external-runtime-design.md`
- `cybros/docs/reports/2026-03-15-claw-openclaw-parity-report.md`

Primary live-code evidence for this audit:

- Kernel/runtime orchestration: `cybros/lib/agent_core/dag/`, `cybros/app/services/run_drafts/`, `cybros/lib/cybros/programmable_agent/`
- Kernel callback and state surfaces: `cybros/app/services/agent_rpc/`
- Program manifest, hooks, and agent-owned tools: `agents/claw/agent.yml`, `agents/claw/lib/cybros/agents/claw/`

Current baseline and environment evidence:

- Baseline commit reviewed: `f858819` (`docs: tighten kernel program audit docs`)
- `pg_isready` on 2026-03-17 returned `accepting connections` before targeted Rails verification
- This pass produces only the audit package and evidence set; it does not refactor product code

Targeted verification completed during this audit:

- `cd /Users/jasl/Workspaces/Cybros/cybros/agents/claw && bin/test`
  - result: pass
  - evidence: `47 runs, 309 assertions, 0 failures, 0 errors, 0 skips`
- `pg_isready`
  - result: pass immediately before Rails verification
  - evidence: `/tmp:5432 - accepting connections`
- `cd /Users/jasl/Workspaces/Cybros/cybros/cybros && bin/rails test test/services/agent_rpc test/lib/agent_core/dag`
  - result: pass
  - evidence: `86 runs, 415 assertions, 0 failures, 0 errors, 0 skips`

Provisional assumptions to confirm later in the audit:

- Workspace bootstrap currently exists in both `cybros` and `claw`, which likely indicates duplicated ownership rather than a deliberate kernel/program split
- Prompt assembly is intentionally split between kernel prompt materialization and `claw` bootstrap prompt content, but the live boundary may still be too entangled
- Experimental `memory` behavior is already partially kernelized through callback-backed storage, so its remaining `claw` surfaces must be reclassified explicitly instead of being grandfathered in

## Kernel / Program Ownership Matrix

| Capability | Primary owner | Live evidence | Audit note |
| --- | --- | --- | --- |
| Conversation DAG orchestration, run lifecycle, and finalization | `cybros` | `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`, `cybros/app/services/run_drafts/conversation_turn_orchestrator.rb`, `cybros/app/services/run_drafts/finalize_service.rb` | Kernel owns planning, task expansion, finalization, stale-binding checks, and turn materialization. `claw` does not own the loop. |
| Runtime protocol contract and capability snapshot pinning | `cybros` | `cybros/app/services/agents/protocol.rb`, `cybros/lib/cybros/programmable_agent/capability_handshake.rb`, `cybros/app/services/agent_rpc/kernel_services/tool_surface_manifest.rb` | `claw` advertises methods and tool catalog, but the kernel validates protocol shape, merges kernel tools with agent tools, and pins the effective snapshot. |
| Agent identity, supported methods, and agent-owned tool catalog declaration | `claw` | `agents/claw/agent.yml`, `agents/claw/lib/cybros/agents/claw/application.rb`, `agents/claw/lib/cybros/agents/claw/rpc_dispatcher.rb` | This is a program concern. `claw` declares supported methods, prompt files, and the agent-side tool catalog exposed through `capabilities.handshake`. |
| Agent-owned tool implementation (`claw:*`) | `claw` | `agents/claw/lib/cybros/agents/claw/tool_executor.rb`, `agents/claw/lib/cybros/agents/claw/tools/` | `claw` executes workspace, skill, memory, and web tools behind `tool.execute`. Kernel routes and constrains them, but does not implement the `claw:` tool bodies. |
| Tool routing, task creation, and hook action enforcement | `cybros` | `cybros/lib/cybros/programmable_agent/hook_envelope.rb`, `cybros/lib/cybros/programmable_agent/hook_action_executor.rb`, `cybros/lib/cybros/programmable_agent/tool_execution.rb` | Kernel validates what hooks may do, rewrites hook-created tasks onto DAG nodes, and performs all routed RPC execution. |
| Conversation memory durability and mutation governance | `cybros` | `cybros/app/services/agent_rpc/callback_dispatcher.rb`, `cybros/app/services/agent_rpc/kernel_services/conversation_memory.rb`, `cybros/lib/cybros/programmable_agent/tool_execution.rb` | Durable memory already lives behind kernel callback services and operation receipts. The remaining `claw` memory tool surface looks like an adapter over kernel-owned semantics, not an independent source of truth. |
| Approval state and public-state mutation control | `cybros` | `cybros/app/services/agent_rpc/callback_dispatcher.rb`, `cybros/app/services/run_drafts/conversation_turn_orchestrator.rb`, `cybros/app/services/run_drafts/finalize_service.rb` | Approval parking, mutation confirmation, and draft finalization are kernel semantics. Hooks may request approval but cannot own approval state directly. |
| Context pressure policy and compaction execution | `cybros` | `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`, `cybros/lib/agent_core/runtime_surface/runner.rb`, `agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb` | Kernel decides when context pressure exists and executes `compact_context`. `claw` can suggest prepend tasks, but compaction remains a kernel/runtime behavior. |
| Subagent orchestration and delegated execution scope | `cybros` | `cybros/lib/cybros/programmable_agent/execution_context.rb`, `cybros/lib/agent_core/dag/executors/agent_message_executor.rb`, `agents/claw/lib/cybros/agents/claw/hooks/before_subagent_spawn.rb`, `agents/claw/lib/cybros/agents/claw/hooks/after_subagent_result.rb` | Kernel carries subagent identity and execution scope. `claw` only reacts through hooks and reduced prompt mode. |
| Agent-specific bootstrap prompt content and hook-authored system instructions | `claw` | `agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`, `agents/claw/lib/cybros/agents/claw/application.rb` | `claw` assembles the program-specific bootstrap sections and staged prompt-buffer writes. This is the clearest current program-owned prompt surface. |
| Final prompt materialization, prompt-injection sources, and memory lookup for the actual LLM call | `cybros` | `cybros/lib/agent_core/dag/prompt_assembly.rb` | The live prompt path is still kernel-heavy: visible tools, prompt injections, lane buffers, and memory lookup are materialized in `cybros`. This is valid only if the kernel owns generic runtime prompt composition rather than agent-specific authoring. |
| Workspace bootstrap for bundled live roots | `claw` | `agents/claw/lib/cybros/agents/claw/workspace_bootstrap.rb`, `agents/claw/lib/cybros/agents/claw/application.rb` | Intended owner appears to be `claw`, but this area already shows mixed ownership because `cybros/app/services/agents/workspace_bootstrap.rb` exists with similar seed behavior. Reclassify in the migration ledger. |
| Silent finalization contract | `cybros` | `cybros/lib/cybros/programmable_agent/hook_envelope.rb`, `cybros/lib/cybros/programmable_agent/hook_action_executor.rb`, `cybros/lib/agent_core/dag/executors/agent_message_executor.rb` | `claw` may request `finish_silently`, but the kernel owns the contract, node mutation, and final delivery semantics. |

## Migration Candidate Ledger

| Candidate | Current owner | Why it was left in `claw` | Recommendation | Rationale | Constraints if it stays in `claw` |
| --- | --- | --- | --- | --- | --- |
| Durable workspace memory documents and mutation governance | Mixed (`claw` tool calls into `cybros` callback services) | OpenClaw-style memory experimentation moved quickly through agent-owned tools | `move to cybros` | `memory` now affects durable state, compaction behavior, and cross-run consistency. `ConversationMemory` is already a kernel service delegating to `WorkspaceMemory`, which writes the real documents. The durable semantics are already kernel-shaped. | If any `claw` layer remains, it must be transport-only and must not create an alternate source of truth. |
| `memory_search` / `memory_get` / `memory_store` as agent-facing tool affordances | `claw` | Tool catalog ownership is intentionally agent-side | `stay in claw` | The tool UX and prompt vocabulary can remain program-owned as long as the tool body is a thin adapter over kernel callbacks. This preserves agent-owned tooling without reintroducing memory ownership drift. | No direct file or database writes except through kernel callbacks; no hidden memory semantics; no compaction policy in the tool layer. |
| Auto-memory flush before compaction | `claw` hook | It was easy to prototype in `on_context_pressure` while parity work was still active | `move to cybros` | Pre-compaction durable capture changes runtime semantics, not just prompt behavior. The current hook prepends `memory_store` before `compact_context`, which couples durable memory policy to one program implementation. | If temporarily retained, it should be limited to status text only and the kernel should own whether any flush task is inserted. |
| Bundled workspace bootstrap and seed files | Mixed (`Agents::WorkspaceBootstrap` and `Cybros::Agents::Claw::WorkspaceBootstrap`) | Bundled claw needed seeded prompts, skills, and memory files quickly | `delete/collapse` | There are two seeders with nearly identical responsibilities, but the `claw` copy has already diverged by adding daily-memory initialization and safer path handling. One implementation should survive. | Surviving bootstrap logic should be explicitly bounded to bundled `claw` concerns and not become a generic kernel-owned prompt/memory policy surface. |
| Bootstrap authority tasks (`cybros_seed_message`, `cybros_generate_title`, `cybros_enqueue_lane_summary`) scheduled from `claw` hooks | `claw` initiating kernel tools | Lightweight hook workflows were cheaper to ship from the agent side | `move to cybros` | These tasks create visible product behavior and durable DAG nodes. They are kernel/product semantics, not program-local reasoning behavior. Current `claw` hooks are effectively product feature toggles. | If kept temporarily, hooks should only reference kernel-owned authority tools and must not invent alternate user-visible flows. |
| `NO_REPLY` parsing and concise output shaping in `before_finalize_output` | `claw` on top of kernel silent-finalization contract | Output style and parity behavior were already agent-specific | `stay in claw` | The kernel already owns the actual `finish_silently` contract. Keeping token parsing and output wording in `claw` is acceptable as a program concern. | `claw` must not bypass the kernel finalization contract or invent hidden delivery semantics. |
| Legacy logical-workspace compatibility payloads (`logical_workspace_key`, `logical_workspace_root_path`, `logical_workspace_initialized_at`) | `cybros` compatibility layer | The runtime was cut over from conversation-owned logical workspace semantics and older consumers still needed fields | `delete/collapse` | Current path resolution is agent-root based, but runtime payloads and attachment descriptors still emit the old logical-workspace fields. This keeps a superseded model alive inside live runtime envelopes. | None. This should not remain a long-lived compatibility surface once runtime consumers are updated. |
| Fixture/scenario mutation tokens inside `before_agent_step` (`stage-state`, `replay-kv`, `switch-target`, `approval`) | `claw` test-oriented logic in production hook code | Contract fixtures were built by reusing the real hook implementation | `delete/collapse` | These are not stable product capabilities. They keep test scaffolding inside the runtime hook and preserve a dead `execution_target` branch. | None. Move scenario behavior into fixtures or harnesses instead of shipping it in the production hook. |

## Findings Ledger

| Action | Decision bucket | Finding | Evidence | Why it matters |
| --- | --- | --- | --- | --- |
| `move` | `Must fix in Phase 1` | Durable `memory` semantics should be kernel-owned, not jointly owned by `claw` tool code and hook policy. | `cybros/app/services/agent_rpc/kernel_services/conversation_memory.rb`, `cybros/app/services/agent_rpc/kernel_services/workspace_memory.rb`, `agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb`, `agents/claw/lib/cybros/agents/claw/hooks/on_context_pressure.rb` | Memory now writes real workspace documents and participates in compaction-related behavior. That is kernel/runtime authority. |
| `thin` | `Keep in claw for now, but constrain` | The agent-facing memory tool contract can stay in `claw`, but only as a thin adapter over kernel callbacks. | `agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb`, `cybros/lib/cybros/programmable_agent/tool_execution.rb` | This keeps tool catalog ownership with the program while preventing a second memory authority from emerging. |
| `merge` | `Must fix in Phase 1` | Workspace bootstrap is duplicated across kernel and program code. | `cybros/app/services/agents/workspace_bootstrap.rb`, `agents/claw/lib/cybros/agents/claw/workspace_bootstrap.rb`, `cybros/app/services/agents/workspace_initializer.rb` | Duplicate seeding logic already diverged. Future refactors will keep splitting prompt/skill/memory bootstrap unless one implementation is removed. |
| `move` | `Strong migration candidate` | Bootstrap authority tasks are product semantics and should not be initiated from `claw` hooks long term. | `agents/claw/lib/cybros/agents/claw/hooks/on_conversation_created.rb`, `agents/claw/lib/cybros/agents/claw/hooks/on_lane_first_user_message.rb`, `cybros/lib/cybros/bootstrap/tools.rb` | Welcome messages, title generation, and lane-summary scheduling create durable user-facing DAG behavior. Those belong with kernel/product orchestration. |
| `delete` | `Delete now` | `execution_target.list` / `planning.execution_target_proposal` is a dead compatibility surface still present in bundled claw hook code and tests. | `agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`, `agents/claw/test/integration/rpc_contract_test.rb`, `cybros/test/integration/programmable_agent_hooks_test.rb` | The kernel hook contract now rejects `execution_target_proposal`, and there is no live app-side `execution_target.*` surface on the main runtime path. Keeping it only preserves abandoned runtime nouns. |
| `delete` | `Strong migration candidate` | `logical_workspace_*` fields remain in runtime payloads and attachment descriptors even though the live workspace model is already agent-root based. | `cybros/app/models/conversation.rb`, `cybros/app/services/conversations/workspace_initializer.rb`, `cybros/app/services/conversations/attachment_transfer_service.rb`, `cybros/test/models/conversation_program_selection_test.rb` | This keeps the old conversation-owned logical workspace model alive in live protocol payloads and complicates the kernel/program boundary. |
| `delete` | `Delete now` | Test fixture scenario logic leaked into the real `before_agent_step` hook. | `agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`, `agents/claw/test/integration/rpc_contract_test.rb` | It expands the shipped hook contract with non-product behavior and makes future audit work harder because test scaffolding looks like runtime policy. |
| `defer` | `Keep in claw for now, but constrain` | Prompt composition is still split between `claw` bootstrap authoring and `cybros` final prompt materialization. | `agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb`, `cybros/lib/agent_core/dag/prompt_assembly.rb` | This is a real boundary seam, but it should be revisited after memory/bootstrap cleanup removes the larger ownership drift. |

## Hot Path And Performance Notes

These are code-structure-based performance notes, not benchmark claims.

| Hot path location | Why it is on the critical path | Evidence | Concern type | Recommended timing |
| --- | --- | --- | --- | --- |
| `cybros/lib/agent_core/dag/context_budget_manager.rb` | Every agent turn builds prompt state here before the LLM call | `build_prompt` prepares once, then `build_until_within_budget` repeatedly rebuilds the prompt as it drops prompt-buffer sections, drops memory, prunes tool outputs, and shrinks turns | duplicated prompt assembly and repeated token estimation | Phase 2 after boundary cleanup |
| `cybros/lib/agent_core/dag/prompt_assembly.rb` | Prompt assembly is executed for each agent step and re-invoked during budget fitting | `prepare` performs memory lookup and prompt-injection collection; `build` re-runs context adaptation, visible-tool filtering, and prompt-pipeline construction | repeated context shaping and prompt materialization | Phase 2 after the memory/bootstrap split is simplified |
| `agents/claw/lib/cybros/agents/claw/hooks/before_agent_step.rb` | Planning hook runs before each agent step | `build_tool_surface` turns the current capability snapshot back into a `tool_surface.manifest` callback RPC, with only a local fallback if that fails | extra RPC and JSON serialization on the planning path | Phase 1 or early Phase 2 |
| `cybros/lib/cybros/programmable_agent/tool_execution.rb` plus `agents/claw/lib/cybros/agents/claw/tools/memory_tools.rb` | Every agent-owned tool call goes through this route, and memory writes are especially chatty | `tool.execute` sends full `session_context` and `execution_context`; `memory_store` then performs `conversation.memory.get` plus `append` or `put` callback RPCs | extra RPC hops and repeated JSON encode/decode | Phase 1 for memory; later for broader tool routing |
| `agents/claw/lib/cybros/agents/claw/application.rb` and `before_agent_step.rb` | Bootstrap prompt content is assembled on the main turn path | `prompt_text` reads workspace or source prompt files, and `before_agent_step` composes bootstrap sections from those files for each planning pass | repeated file I/O and prompt-source assembly | Phase 2 once bootstrap ownership is simplified |

## Delete Now List

- Remove the legacy `execution_target.list` callback path and `planning.execution_target_proposal` expectations from bundled `claw` hook code, callback harnesses, and contract tests. The kernel hook contract already rejects that field, and no current app/runtime code consumes it.
- Archive the legacy `2026-03-08` and `2026-03-09` runtime planning docs and remove active links that still treat them as current inputs. They still present removed runtime nouns as live design inputs.
- Extract or remove fixture-only scenario token behavior from the production `before_agent_step` hook so test-only staging flows are no longer shipped as part of the bundled runtime.

## Documentation Drift

Current product-facing docs appear largely aligned with the newer runtime split:

- `cybros/README.md`
- `agents/claw/README.md`
- `cybros/docs/product/`
- `cybros/docs/agent_core/`
- `cybros/docs/dag/`

Targeted drift search did not find current mentions of `AgentProgram`, `AgentDeployment`, `ExecutionTarget`, `ExecutionLocation`, `managed-local`, or `in-process host` in those active product/runtime docs.

The active drift is concentrated in older plan documents that still live under `cybros/docs/plans/` instead of archive.

| Source document | Conflicting newer evidence | Recommended action | Why it misleads later work |
| --- | --- | --- | --- |
| `cybros/docs/archive/plans/2026-03/2026-03-08-runtime-governance-design.md` and `cybros/docs/archive/plans/2026-03/2026-03-08-runtime-governance.md` | `cybros/docs/plans/2026-03-13-conversation-agent-runtime-simplification-design.md`, current app/tests showing agent-root workspaces and `Agent` as the public binding | Archive | These docs still assign live ownership to `ExecutionLocation`, `Workspace`, and `ExecutionTarget`. |
| `cybros/docs/archive/plans/2026-03/2026-03-09-agent-deployment-connection-design.md` | `cybros/docs/plans/2026-03-13-conversation-agent-runtime-simplification-design.md`, `cybros/test/models/conversation_program_selection_test.rb` | Archive | It still frames `AgentProgram` as the selectable identity, which conflicts with the shipped `Conversation -> Agent` binding. |
| `cybros/docs/archive/plans/2026-03/2026-03-09-automation-runtime-design.md` | Later runtime simplification design and current `Agent`-centric workspace/runtime tests | Archive | It keeps automations bound to `AgentProgram`, which is no longer the product/runtime anchor. |
| `cybros/docs/archive/plans/2026-03/2026-03-09-execution-target-discovery-design.md` | Current hook contract rejects `execution_target_proposal`; live app grep shows no active `execution_target.*` path on the runtime hot path | Archive | It documents a selection surface the current runtime is actively trying to delete. |
| Live runtime payload naming (`logical_workspace_*`) in `cybros/app/models/conversation.rb` and `cybros/app/services/conversations/attachment_transfer_service.rb` | `cybros/README.md`, `cybros/test/models/conversation_program_selection_test.rb`, `cybros/test/integration/bundled_agent_parity_test.rb` | Rename or remove after runtime consumer cutover | Code is still exporting old workspace nouns even though the docs and tests now describe an agent-root workspace model. |

## Phase Plan

### Phase 1 Must-fix

- Move durable memory semantics and pre-compaction flush policy into `cybros`, keeping only a thin `claw` tool adapter.
- Delete legacy `execution_target.list` / `planning.execution_target_proposal` logic from bundled `claw` and its contract harnesses.
- Collapse duplicate workspace bootstrap implementations so one bounded seeding path survives.
- Remove fixture/scenario mutation logic from the production `before_agent_step` hook.

### Strong migration candidates

- Move bootstrap authority task scheduling (`cybros_seed_message`, `cybros_generate_title`, `cybros_enqueue_lane_summary`) into `cybros`.
- Remove `logical_workspace_*` compatibility fields from runtime payloads and attachment descriptors after runtime consumer cutover.
- Revisit whether `tool_surface.manifest` needs a callback round trip on every planning step or can be derived more directly from the pinned capability snapshot.

### Keep in claw for now, but constrain

- Keep the agent-facing memory tool affordances in `claw`, but only as stateless adapters over kernel callbacks.
- Keep `NO_REPLY` parsing and output wording in `claw`, but do not let it bypass kernel finalization semantics.
- Keep agent-specific bootstrap authoring in `claw` for now, while constraining kernel prompt materialization to generic runtime composition instead of agent-specific policy.

### Delete now

- Archive or clearly supersede the older active plan docs that still treat `AgentProgram`, `AgentDeployment`, `ExecutionTarget`, and `ExecutionLocation` as current product/runtime anchors.
- Delete the dead execution-target proposal branch from bundled `claw`.
- Delete fixture-only staging branches from the shipped `before_agent_step` hook.

## Big-bang Cutover Appendix

Minimum cut line for a one-shot refactor:

- make `cybros` the only owner of durable memory semantics, compaction-triggered flush policy, bootstrap authority tasks, and runtime workspace payload naming
- keep `claw` limited to tool catalog declaration, thin tool adapters, prompt/bootstrap authoring, and bounded output shaping
- remove all live `execution_target` and `logical_workspace` compatibility surfaces in the same pass

Highest-risk dependency chain:

- `Conversation.workspace_payload` and attachment descriptors still emit legacy workspace fields
- those payloads feed `tool.execute` request envelopes
- `claw` tool routing still reads both new and legacy workspace keys
- `memory_store` and context-pressure hooks then depend on those payloads while also invoking kernel callbacks

If this is cut in one destructive pass, workspace payload renaming, memory ownership transfer, and tool adapter thinning have to land together.

What should be removed immediately in a destructive cutover:

- `planning.execution_target_proposal` and `execution_target.list`
- fixture/scenario branches in `before_agent_step`
- duplicated workspace bootstrap implementation
- `logical_workspace_*` fields from live runtime envelopes once consumers are updated
- old runtime-shape plan docs from active `docs/plans/`

## Handoff Note

Start with the phased path.

Explicit user selection is still needed for these migration candidates before coding:

- whether bootstrap authority tasks should move fully into `cybros` now or remain temporarily hook-triggered behind a narrow compatibility window
- whether the surviving workspace bootstrap implementation should live as a bundled-`claw` seeder called by `cybros`, or as a shared utility extracted from both copies

Safe immediate deletions:

- dead `execution_target` proposal surfaces in bundled `claw`
- fixture-only scenario branches inside the real `before_agent_step` hook
- stale active plan docs that still advertise removed runtime nouns as current architecture
