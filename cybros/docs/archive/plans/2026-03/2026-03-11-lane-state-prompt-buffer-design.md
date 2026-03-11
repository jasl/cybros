# Lane-Scoped State and Prompt Buffer Design

## Status

Approved design notes for moving agent working state and prompt summaries out of conversation-global storage and into lane-scoped state.

## Decisions

### 0. This is a destructive replacement, not a compatibility rollout

- This work is a destructive cut.
- The standing product agreement applies:
  - breaking changes are acceptable
  - compatibility shims are not required
  - database reset is allowed if that simplifies the cut
- Prefer deleting superseded state-management behavior over preserving dual paths.
- V1 must fully migrate the existing behavior onto the new lane-state model rather than leaving split semantics behind.
- After the cut, superseded concept names should remain only in explicitly archived docs under `docs/archive`.
- In particular, V1 should remove or retire:
  - `conversation.kv.*` as the primary programmable-agent mutable state surface
  - active-path assumptions that prompt summaries live only as DAG-compaction artifacts
  - docs that describe DAG history alone as the full prompt-working-set story

### 1. DAG remains durable source of truth only

- DAG remains the durable system of record for:
  - messages
  - tasks
  - summary nodes
  - visibility state
  - turns
  - lanes
  - branching and merge structure
  - auditability
- DAG does **not** own prompt-side working state.
- Prompt-side working state must move to lane-scoped storage that is orthogonal to DAG history assembly.

### 2. Conversation remains the top-level container

- Do not reintroduce a `topic` entity.
- Root and child conversations continue to use `Conversation`.
- Branch-local working state is attached to `lane`, not to a new product concept.
- `Conversation#create_child!` and child-conversation lane attachment remain the canonical product fork path and must be covered by the migration.

### 3. State splits into conversation-scoped and lane-scoped surfaces

- `conversation.settings` and `conversation.config` remain conversation-scoped.
- New branch-local state surfaces are:
  - `lane.kv`
  - `lane.prompt_buffer`
- These surfaces are the correct home for agent working state that should fork with a branch and stay isolated afterward.

### 4. `lane.kv` replaces `conversation.kv`

- Generic programmable-agent mutable state should no longer be conversation-global.
- `conversation.kv.*` is replaced by `lane.kv.*`.
- `lane.kv` is for structured, branch-local state.
- It is not specialized for prompt rendering.
- V1 public API:
  - `lane.kv.get`
  - `lane.kv.set`
  - `lane.kv.delete`
  - `lane.kv.list`
  - `lane.kv.snapshot`

### 5. `lane.prompt_buffer` is the new prompt-side working-set primitive

- `lane.prompt_buffer` is a lane-scoped, named, ordered prompt-material store.
- It is **not** a stack.
- It is **not** a replacement for DAG summary nodes.
- It is **not** auto-injected into prompts; the agent program decides when and how to read from it.
- Recommended buffer names include:
  - `summaries`
  - `working_notes`
  - `handoff`
- The API should keep `buffer_name` open-ended rather than hard-enum the list.

### 6. `lane.prompt_buffer` entry model stays minimal and token-aware

- Each prompt-buffer entry should have at least:
  - `id`
  - `seq`
  - `kind`
  - `content`
  - `priority`
  - `estimated_tokens`
  - `metadata`
  - `created_at`
- `estimated_tokens` is computed by Cybros when the entry is written.
- The agent does not supply authoritative token counts.
- V1 should not add:
  - nested entries
  - implicit replacement rules
  - hard binding to DAG node ids
  - hidden partial truncation inside a single entry

### 7. `lane.prompt_buffer.render` is the core read primitive

- The prompt-buffer abstraction is valuable because it can render a bounded prompt section under a token budget.
- `render` is a read-only operation.
- It does not mutate the buffer.
- V1 `render(max_tokens:)` should:
  - select entries under the token budget
  - return a prompt-ready result
- Default selection policy:
  - select by `priority DESC, seq DESC`
  - return selected content ordered by `seq ASC`
- Oversized single entries are not partially truncated by the kernel.
- Instead, `render` reports them as oversized and leaves rewriting/compaction to the agent program.
- V1 result should include:
  - `content`
  - `entries`
  - `entry_ids`
  - `estimated_tokens`
  - `truncated`
  - `remaining_entries_count`
  - `oversized_entry_ids`

### 8. Token estimation becomes a first-class public API

- Prompt-buffer writing and rendering require stable token estimation.
- Cybros already has token counters internally, but V1 should expose a formal public API:
  - `tokens.estimate_text`
  - `tokens.estimate_messages`
- Do not make `estimate_prompt` part of the minimum cut unless implementation turns out to be trivial.
- `lane.prompt_buffer` should use this same token-estimation authority rather than inventing its own counting rules.

### 9. Fork semantics are frozen-snapshot and fully independent

- Forked lane state is based on a frozen snapshot taken at fork time.
- After fork:
  - child lane state is fully independent
  - parent changes are not visible to child
  - child changes are not visible to parent
- The external contract is independent snapshot semantics.
- Internal implementation may use physical copy or snapshot-plus-delta, but it must not behave like a live parent overlay.

### 10. Merge does not implicitly merge lane state

- Lane merge must not silently combine `lane.kv` or `lane.prompt_buffer`.
- DAG merge remains structural:
  - create an explicit join node in the target lane
- Lane-state merge must be explicit and auditable.

### 11. V1 merge uses an explicit `merge_lane_state` task

- Product-level merge should materialize a normal DAG task such as:
  - `task(name: "merge_lane_state")`
- This must migrate the existing product-level merge path rather than introduce a second parallel merge mechanism.
- In practice, V1 should migrate `Conversation#merge_into_parent!` away from an `agent_message` join placeholder and onto an executable task boundary.
- The merge boundary must execute through the ordinary task/runtime contract rather than stopping at a metadata-only join node.
- The task receives frozen snapshots, not live lane state.
- Minimum task input:
  - `target_lane_id`
  - `source_lane_ids`
  - `target_lane_kv_snapshot`
  - `source_lane_kv_snapshots`
  - `target_prompt_buffer_snapshot`
  - `source_prompt_buffer_snapshots`
  - `merge_metadata`
- Minimum task output:
  - `target_lane_kv_patch`
  - `target_prompt_buffer_patch`
  - `summary`
  - `conflicts`
  - `archive_source_lanes`
- The engine validates the result and atomically applies it to the target lane.
- The agent program decides how to merge:
  - pure code
  - LLM-assisted
  - hybrid

### 12. No separate merge hook in V1

- V1 should not add a dedicated merge hook.
- Merge already has an explicit task boundary.
- That task boundary is sufficient for:
  - audit
  - approval/policy
  - LLM-assisted strategy
  - code-only strategy
- Adding a second merge-only hook would increase concepts without clear immediate benefit.

### 13. Context management becomes a three-layer model

- Long-term context management should be understood as:
  - `DAG history window`
  - `lane.prompt_buffer`
  - `token budget`
- These roles are distinct:
  - `DAG history window` provides the durable historical source material
  - `lane.prompt_buffer` provides prompt-side summaries, notes, and compacted working material
  - token budget decides what fits
- This means prompt-side context handling should no longer be modeled as DAG history assembly alone.

### 13.1. Default agent context management should migrate to `lane.prompt_buffer`

- This cut should not stop at moving compaction or budget inputs.
- The bundled/default agent context-management path should also switch to the new prompt-side substrate.
- In practice that means prompt assembly should combine:
  - durable history from the DAG history window
  - prompt-side summaries/notes/handoff material rendered from `lane.prompt_buffer`
- `PromptAssembly` / `ContextAdapter`-level defaults should therefore stop assuming that prompt-side summaries live only in DAG history or summary nodes.
- Soft/hard context-budget evaluation should operate on the prompt produced by that lane-buffer-backed context manager rather than on a separate legacy history-only assembly path.

### 14. DAG `summary` nodes remain durable graph compaction artifacts

- DAG `summary` nodes remain useful for:
  - graph-native history compaction
  - audit
  - replay
  - context-window history substitution
- They are not replaced by `lane.prompt_buffer`.
- `lane.prompt_buffer` is prompt-side working material.
- `summary` nodes remain graph-side durable history artifacts.

### 15. `compact_context` should migrate toward prompt-buffer-first behavior

- Existing compaction logic should be migrated where appropriate so prompt-side summaries and notes live in `lane.prompt_buffer`.
- `compact_context` should evolve toward managing:
  - prompt-buffer entries
  - context visibility choices
  - graph compaction only where durable historical compaction is actually intended
- This keeps prompt-working-set management and graph-history compaction separate.
- Existing soft/hard context-budget behavior should survive this substrate change without a second budget-policy redesign; only the prompt-working-set layer changes.

### 16. All lane-state mutations remain Cybros-owned and auditable

- Agent programs must not directly mutate persistent lane state.
- As with other public execution APIs:
  - the agent declares intent
  - Cybros validates and materializes the effect
- This applies to:
  - `lane.kv`
  - `lane.prompt_buffer`
  - merge results
- Where practical, mutations should remain attributable and auditable in the same spirit as DAG task materialization.

### 17. Follow-up work deliberately left out of this cut

- Do not combine this cut with:
  - agent-program-contributed tools / MCP / skills overlays
  - generalized lifecycle hook surface
  - UI-first branch merge product features
- Those can adopt the same lane-state model later, but they are not required for the initial destructive cut.

## Consequences

- Programmable-agent state becomes branch-correct by default.
- Prompt summaries and notes gain a dedicated token-aware substrate.
- Context management becomes more maintainable because DAG history and prompt working state stop competing for the same abstraction.
- Existing programmable-agent state and docs must be migrated or deleted rather than left half-active.
