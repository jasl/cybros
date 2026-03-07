# Conversation Input Policies Design

## Summary

This design defines the planned product and engine behavior for:

- manual retry vs automatic retry limits
- multi-message user input coalescing across all entrypoints
- user input that arrives while an agent turn is pending or running
- `steer_current_turn` as a same-turn versioned correction flow
- interrupted partial assistant output handling
- oversized input handling for both single-message and multi-message/context overflow

The goal is to keep the DAG expressive and auditable without forcing product policy into the engine core.

## Goals

- Remove retry-count limits from manual user-triggered retry.
- Keep automatic retry bounded and separate from manual retry.
- Treat a burst of short user messages as one logical user turn when the agent has not started executing yet.
- Support clear product-layer strategies for user input that arrives while a turn is in flight.
- Handle oversize input in a way that preserves auditability and leaves room for future automation.
- Express all important outcomes in the DAG, not just in transient UI state.

## Non-goals

- Implement automatic workspace revert / cleanup for interrupted coding turns or steer-driven side effects.
- Introduce durable history compaction `summary` nodes for every overflow case in the first pass.
- Expose every policy branch as a rich user-facing UI control in the first pass.

## Decision 1: Manual retry vs automatic retry

Manual retry and automatic retry are different classes of behavior and must not share the same limit.

- **Manual retry**
  - no retry-count limit
  - still blocked by graph/topology safety constraints
  - still blocked when another retry is already queued or running
  - retry depth remains recorded for audit/stats only
- **Automatic retry**
  - remains bounded
  - should continue to live in recovery/retry policy logic, not in app action availability for human-triggered retry

### Consequence

The current retry depth gate in `Conversation::NodeActionPolicy#retry_entry` should be removed for human retry.

## Decision 2: Policy resolution order

The product must support defaults plus overrides. The engine records the resolved outcome; it does not derive policy by itself.

### 2.1 Static policy precedence

1. app / channel override
2. conversation metadata override
3. `agent_profile` default
4. global default

This static precedence applies to:

- coalescing behavior
- running-input behavior
- interrupted-output default behavior
- oversize handling defaults
- steer capability
- steer cleanup policy
- steer-after-side-effects policy

### 2.2 Action-time override precedence

Certain actions re-evaluate interrupted output handling at the moment the action is taken.

- `retry`
- `steer_current_turn`

These actions may accept an explicit:

- `interrupted_output_policy_override`

When present, it outranks all static defaults.

Final precedence for those actions:

1. action-level override (typically user/product initiated)
2. app / channel override
3. conversation metadata override
4. `agent_profile` default
5. global default

This action-time override precedence applies only to interrupted-output handling on retry/steer actions; it does **not** imply action-time overrides for coalescing, running-input, oversize, or steer capability unless those are explicitly added later.

## Decision 3: Message coalescing across all entrypoints

Coalescing applies to all entrypoints, not just future IM integrations.

### Core behavior

- A burst of short user messages should be treated as one logical user turn.
- If the downstream assistant node exists but has not started executing yet, new user fragments continue to merge into that same logical turn.
- The final DAG-visible `user_message` stores:
  - merged text in `content`
  - original fragments in `metadata["fragments"]`
- The downstream assistant node uses a persisted `claim_after_at` gate on `dag_nodes` so it can remain `pending` but non-claimable during the coalescing window.
- Scheduler claim logic must explicitly filter `pending` nodes by `claim_after_at IS NULL OR claim_after_at <= now`.

### Why

- Keeps the DAG aligned with logical conversation turns rather than transport-layer noise.
- Supports IM-style rapid-fire messages without polluting the graph.
- Preserves auditability of the original fragments.

## Decision 4: Input that arrives while an assistant turn is running

The planned implementation supports three explicit strategies:

- `queue`
- `interrupt_new_turn`
- `steer_current_turn`

`queue` must be treated as a first-class product strategy, not merely as an incidental consequence of dependency edges.

### 4.1 Queue

- Current agent turn continues running.
- New user input is buffered.
- Once the running turn finishes, the buffered input becomes a new turn.

This matches the existing queue-policy scenario already covered in `test/scenarios/dag/user_input_while_running_flow_test.rb`.

### 4.2 Interrupt and start a new turn

- Current running agent turn is interrupted.
- New user input becomes a new turn.
- The interrupted assistant output is preserved in the transcript/UI.
- The new `user_message` sequences from the interrupted assistant turn's last stable sequence parent, not from the interrupted assistant node itself.
- Any pending/running descendants in the interrupted causal closure must be canceled, stopped, or otherwise prevented from remaining claimable before the new turn proceeds.

This matches the current restart-style scenario already represented in `test/scenarios/dag/user_input_while_running_flow_test.rb`.

### 4.3 Steer the current turn

- Current running agent turn is interrupted.
- The same logical turn is retained.
- A new user-input version becomes the effective input for that logical turn.
- If steer is unavailable for the current profile/policy combination, the product falls back to `interrupt_new_turn`.

## Decision 4A: Web chat surface for queue / steer / candidate input

The web `conversation` page must expose these new interaction states explicitly. They should not remain implicit engine behavior.

### Recommended composer surface

Add a unified composer-adjacent status area above the text input:

- **composer status rail**

This rail should be the primary home for:

- queue state
- steer capability / active mode hints
- candidate next-input preview
- lightweight policy explanations relevant to the current composer state

### Why a status rail

- keeps queue/steer state near the composer where the user acts on it
- avoids overloading the footer button strip
- avoids treating every input-policy state as an alert
- aligns with the older Tavern Kit pattern where suggestions/candidates live above the form

### Suggested component shape

Prefer an extracted partial/component such as:

- `app/views/conversations/_composer_status_rail.html.erb`

Possible sections:

- **Queue indicator**
  - visible when buffered input exists or when the next turn is intentionally queued
  - placed above the input field
- **Candidate next input preview**
  - compact preview of the currently buffered/coalesced/steered text
  - useful for IM-like rapid-fire input and future steer UX
- **Steer hint / mode indicator**
  - only when steer is available or selected

### Transcript vs composer responsibility

- `product_message` remains the correct transcript surface for hard oversize guard responses
- queue/steer state should primarily live in the composer rail, because it is transient composer state rather than a completed turn result

This separation should remain true when the future tool-progress redesign lands:

- assistant bubble `run_state` should describe assistant-owned execution
- queue / steer / candidate-next-input rail state should remain composer/conversation state
- preflight policy tasks such as `compress_input` / `compact_context` should not automatically be folded into assistant-bubble execution state

### Reference alignment

Useful reference patterns already exist in the older app:

- candidate/suggestion area above the message form
- queue/status-oriented pre-input UI

The current Cybros conversation page should not copy that UI literally, but it should reuse the same placement logic: state that changes how the next send behaves belongs above the input.

## Decision 5: Interrupted partial output policies

Interrupted partial assistant output has two policies:

- `discard_context`
- `keep_context`

These are separate from the higher-level action (`queue` vs `interrupt_new_turn`).

For actions that intentionally revisit an interrupted or partially-complete turn:

- `retry`
- `steer_current_turn`

the product may pass an action-level `interrupted_output_policy_override` so that one operation can intentionally differ from the conversation default.

For `steer_current_turn`, the override applies to the **superseded block as a unit**:

- superseded user-input version
- interrupted assistant partial output

### 5.1 `discard_context`

- interrupted assistant output remains visible in transcript/UI
- interrupted assistant output is excluded from future prompt context
- recommended default for coding / vibe-coding style agents

### 5.2 `keep_context`

- interrupted assistant output remains visible in transcript/UI
- interrupted assistant output remains part of future prompt context
- recommended default for general chat-style agents

### DAG expression

The DAG can already express both outcomes:

- `stop!` marks the interrupted assistant turn
- `exclude_from_context!` / `context_excluded_at` controls future prompt visibility

### Deferred follow-up

For coding/vibe-coding, `discard_context` may eventually require a second, orthogonal policy:

- `workspace_cleanup_policy = none | revert_workspace`

This is intentionally out of scope for the first pass.

## Decision 6: Oversize input taxonomy

Oversize handling should distinguish between:

- **single-message oversize**
- **multi-message/history/context oversize**

These are different product problems and should not share one blunt “compress everything” rule.

### 6.1 Single-message soft oversize

If one user message is only slightly over the acceptable input budget:

- default behavior: automatically run `compress_input`
- original user text remains preserved
- compressed text is fed to the main assistant turn
- the compressed form should be represented by an explicit preflight `task(compress_input)` result rather than hidden mutation of the original `user_message`

### 6.2 Single-message hard oversize

If one user message is so large that it would crowd out the rest of the turn/context budget:

- persist the raw `user_message` into the DAG
- produce a visible, product-owned `product_message`
- ask the user to shrink/split/edit the input rather than silently compressing it
- `product_message` is non-executable and non-retriable by type/body support hooks, so it does not inherit normal assistant actions

This keeps auditability intact and gives the product a clean place to later attach actions like “compress for me” or “split into segments”.

### 6.3 Multi-message/history/context oversize

If the problem is not one giant message but accumulated turn/context size:

- first-pass behavior: route through a transient `task(compact_context)`
- do **not** immediately force a durable `summary` node into the history
- allow a hybrid strategy:
  - deterministic fast-path for obvious cases
  - utility-agent / controlled hook for ambiguous cases

### 6.4 First-pass oversize policy configuration surface

The first pass should treat oversize handling as configurable policy, not hidden heuristics.

Static defaults should define at least:

- soft single-message oversize threshold/budget
- hard single-message oversize threshold/budget
- soft single-message default strategy (`compress_input`)
- hard single-message default strategy (`product_guard`)
- multi-message/context overflow default strategy (`compact_context`)

For low-interaction / automated channels (for example IM/webhook/bot adapters), app/channel overrides may additionally choose more automated hard-oversize handling, such as:

- `compress_input`
- `exclude_latest_and_emit_notice`
- `compact_context_then_run` (for context/history overflow)

## Decision 7: Hybrid oversize decision mode

The first pass uses a hybrid strategy:

- clear “within budget” cases pass through
- mild oversize uses deterministic `compress_input`
- severe/ambiguous cases can route through a utility-agent / preflight task
- single-message hard oversize defaults to product-layer user handling

This avoids making the main assistant responsible for deciding whether it can even read the input.

## Decision 8: DAG expression for oversize flows

### Single-message hard oversize

Recommended DAG shape:

- `user_message`
- optional internal guard/task metadata
- visible `product_message` describing the issue and available next actions

### Single-message soft oversize

Recommended DAG shape:

- `user_message`
- `task(compress_input)`
- main `agent_message`

### Multi-message/context oversize

Recommended first-pass DAG shape:

- `user_message`
- `task(input_guard)` or `task(compact_context)`
- main `agent_message`

Durable `summary` nodes remain a later optimization / compaction feature, not the default first-pass response to every overflow case.

### Boundary with existing `AgentCore` auto-compaction

`compact_context` does **not** replace `AgentCore`'s existing `auto_compact` flow.

- `compact_context` is an app-layer, pre-turn overflow response used before the main assistant execution starts
- `auto_compact` remains an engine-layer execution-time fallback inside prompt assembly and may still materialize durable `summary` nodes later if budget pressure persists

These two mechanisms therefore have different ownership:

- app-layer `compact_context`: explicit product/input policy
- engine-layer `auto_compact`: runtime budget management fallback

## Decision 9: `steer_current_turn`

`steer_current_turn` is part of the planned implementation scope, but its workspace cleanup policy remains deferred.

### Core meaning

Steer is not modeled as “open a new turn”. It is modeled as:

- the same logical turn
- a new user-input version
- replacement of the current turn’s effective user intent

This makes it closer to version replacement (`edit`-style semantics) than to ordinary message append.

### Recommended DAG semantics

- create a new user-input version inside the same logical turn
- treat the superseded user-input version plus interrupted assistant partial as one superseded block
- old user-input version exits the normal transcript
- old user-input version remains available for audit/version history

### Capability gating

Steer is not automatically available to all profiles.

- steer capability follows the same static precedence model as other policies
- app/channel override may disable or enable steer where appropriate
- conversation metadata may override profile defaults
- if steer is unavailable, the product should fall back to `interrupt_new_turn`

### Cleanup semantics

Steer does not itself define how side effects are reverted.

Instead, it reads a separate static policy:

- `steer_cleanup_policy`

This policy follows the same static precedence model:

- app/channel override
- conversation metadata override
- `agent_profile`
- global default

### Side-effect boundary

Whether steer remains allowed after tool side effects have already happened is also policy-driven:

- some profiles may disallow steer after side effects
- some profiles may allow it

In the planned first implementation, actual workspace cleanup/revert remains TODO. Profiles that enable steer after side effects are therefore opting into “semantic steer first, cleanup later”.

### Transcript and context behavior

Recommended defaults:

- old user-input version: hidden from normal transcript, kept in audit/version history
- old assistant partial output: handled together with the superseded user-input block, not as an orphaned standalone message
- `discard_context`: the whole superseded block becomes audit-only and leaves future prompt context
- `keep_context`: the whole superseded block remains available in future prompt context and version history, while normal first-pass transcript rendering may continue to hide superseded versions

## Existing Codex reference alignment

The Codex reference supports the overall direction:

- `turn/interrupt` exists for in-flight interruption
- `turn/steer` exists for mid-turn user input without opening a new turn
- Codex source also distinguishes history compaction behavior from ordinary turn processing

That supports keeping:

- queue / interrupt in the first pass
- steer as a first-pass advanced capability with explicit capability gating and fallback
- history overflow as a compaction-class problem rather than a single-message problem

## Planned implementation scope

Include now:

- manual retry unlimited
- all-entrypoint coalescing
- `queue`, `interrupt_new_turn`, and `steer_current_turn`
- web chat composer status rail for queue / steer / candidate preview
- `discard_context` and `keep_context`
- action-level `interrupted_output_policy_override` for `retry` and `steer_current_turn`
- single-message soft/hard oversize split
- transient `compact_context` path for multi-message/history overflow

Defer:

- workspace revert / cleanup after interrupted coding output
- durable `summary` nodes as the default overflow response
- rich user-facing controls for every policy override

## Residual risks and follow-ups

These items do not block the current plan, but they should stay visible during implementation:

- **Coalescing race at the claim boundary**
  - `claim_after_at`-style gating must be exercised under race tests so “fragment arrives just as claim starts” behaves deterministically.
- **Synthetic hard-oversize guard message shape**
  - Prefer a dedicated non-executable `product_message` from the start so guard responses do not inherit assistant actions or prompt semantics.
- **Steer transcript vs prompt divergence**
  - First-pass steer may keep superseded blocks in audit/history or prompt context while hiding them from the normal transcript. Product UX should later expose version history more clearly.
- **Pre-turn `compact_context` vs engine `auto_compact`**
  - These are intentionally separate layers. Even after app-layer preflight compaction lands, engine-layer durable summaries may still appear later under runtime budget pressure.
- **Workspace cleanup remains TODO**
  - `steer_cleanup_policy` and interrupted coding cleanup are policy-shaped now, but real side-effect rollback is intentionally deferred.
- **Future tool-progress redesign depends on these transcript/supersession rules**
  - Once input policies land, the tool-progress plan should be revised against the final `interrupt_new_turn`, `steer_current_turn`, hidden-version, and `messages/refresh` semantics before implementation starts.
