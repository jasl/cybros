# Pending Agent Recovery Design

## Summary

This design defines two complementary recovery behaviors for chat-lane `agent_message` nodes that never started executing:

- a manual `Start` action for the tail `pending agent_message`
- an automatic silent repair when a new user message arrives behind an unstarted pending agent

The goal is to let users recover from scheduler stalls without exposing DAG internals or polluting transcript/context with abandoned assistant placeholders.

## Goals

- Allow the user to manually start the last `pending agent_message` from the Web UI.
- Make manual start race-safe: if the node is no longer the tail pending assistant when the request executes, fail cleanly.
- When a new user message arrives behind an unstarted pending assistant, silently discard that assistant and continue from the last stable parent.
- Ensure abandoned pending assistant nodes do not remain visible in transcript or future prompt context.

## Non-goals

- Allow starting arbitrary queued/pending assistant nodes that are blocked by earlier turns.
- Expose abandoned pending assistant nodes as visible “stopped” transcript artifacts.
- Add a background sweeper as the primary recovery path.

## Decision 1: Manual start only applies to the tail pending assistant

The `Start` action is intentionally narrow:

- only `agent_message`
- only `state == pending`
- only when `claimed_at` and `started_at` are both blank
- only when the node is the current chat-lane tail assistant
- only when there is no later user message or later pending assistant behind it

This keeps the button semantics simple: “start the thing that should be running right now”.

## Decision 2: Auto-repair happens in the append path, not a sweeper

When the append path sees:

- no currently running/awaiting-approval assistant
- the chat tail is an unstarted `pending agent_message`
- the user is appending a fresh message

the app silently archives the pending assistant and its queued run, then creates the new user turn from the pending assistant’s stable sequence parent.

This produces the behavior users expect:

- they type again
- the stale placeholder disappears
- the newest input becomes the active tail

## Decision 3: Silent archive means hidden from transcript and context

The abandoned pending assistant should not surface as a visible transcript row and should not participate in future prompt context.

Implementation-wise, the node should become terminal and be marked deleted/context-excluded before the new tail is built.

## Decision 4: Races are resolved under the graph lock

Both manual start and silent repair must re-check their invariants inside the graph lock:

- `Start` succeeds only if the node is still the tail pending assistant at mutation time.
- Appending a new user message repairs only if the stale pending assistant still matches the silent-repair predicate at mutation time.

If `Start` loses the race to a new user message, it returns a conflict-like app error and the UI refreshes.

## Recommended UI behavior

- Reuse the existing message action system on assistant bubbles.
- Show `Start` only when action policy marks it available.
- If a start request fails because state changed, show a lightweight toast and refresh.

## Testing

- policy test for `Start` availability
- UI integration test for the `Start` button
- conversation facade test for silent repair when appending behind a stale pending assistant
- conversation/controller test for manual start transitioning the tail pending assistant into execution
