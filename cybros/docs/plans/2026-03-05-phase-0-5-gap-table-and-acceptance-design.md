# Phase 0.5 gap table + acceptance (temporary) — Design

## Why

Phase 0.5 is explicitly about shipping a **product-grade UI skeleton** and making **chat transport** (Turbo Streams + ActionCable) robust enough to become the reusable “conversation event stream” model.

We already refactored the App layer to be **Conversation-first** (DAG is internal). The remaining work for Phase 0.5 should be driven by **acceptance** and the **edge/extreme test matrix**, not by incremental ad-hoc fixes.

This document is **temporary**: once Phase 0.5 is shipped and acceptance is met, we can delete it or move it to an archive folder.

## Goals

- Produce a single “implementation gap table” for **all of Phase 0.5**.
- Use the table to drive work until:
  - Acceptance Criteria are satisfied
  - Edge/extreme test matrix is implemented and passing
- Keep App code **Conversation-only** at the boundary (no `DAG::*` from controllers/channels/views).

## Non-goals

- Long-term governance. This is a working spec to get Phase 0.5 over the line.
- Perfect UI polish. We prioritize correctness, convergence, and clear UX for failures.

## Recommended approach (chosen)

Use **Acceptance Criteria + Edge/extreme test matrix** as the **primary table**.

- Milestones sections (`0.5-A0/A/B/C/D/E/F/...`) are referenced as context and cross-links, but we avoid duplicating the same requirement three times.

## Gap table format

### Columns

- **Item**: a single acceptance/test requirement (atomic and verifiable).
- **Status**:
  - ✅ complete (implemented + covered or trivially verifiable)
  - 🟡 partial (some pieces exist; missing invariants/tests/UX)
  - ❌ missing (no meaningful implementation yet)
- **Evidence**: pointers to the current implementation.
  - Prefer `path::Class#method` or `path` + the exact route/channel name.
  - When it’s behavior-only: describe the observable behavior in one sentence.
- **Gap**: what is missing (be explicit).
- **Next step**: the smallest safe change that moves it forward.
- **Test coverage**: which test(s) prove it (or “TODO” if missing).

### Grouping (table sections)

- **Layouts & shell** (0.5-A0/A)
- **Pages** (0.5-B)
- **Transport & ordering invariants** (0.5-C)
- **Chat UX state machine** (0.5-D)
- **Observability & debuggability** (0.5-E)
- **Auth/pagination/throttle/broadcast hardening** (0.5-F)
- **Edge/extreme test matrix (required)** (test matrix section)

## Prioritization

Work order is driven by user impact and risk:

1. **Transport correctness + convergence**
   - reconnect/resume dedupe
   - ordering invariants (rapid sends, pairing)
   - durable truth reconciliation (`messages/refresh`)
2. **Failure UX**
   - stop/retry/regenerate semantics, error surfaces, stuck detection
3. **Hardening**
   - throttling, broadcast error visibility, ownership checks
4. **Layout + pages completeness**
   - ensure layout routing is correct across surfaces
5. **Follow-ups / polish**
   - hotkeys, action layer, perf/backlog items (e.g., narrow MutationObserver scope)

## Verification strategy

- Prefer **integration/system-level tests** for transport invariants.
- Keep targeted unit tests where they help isolate logic (e.g., event ordering helpers).
- Local verification should include:
  - rapid send
  - disconnect/reconnect mid-stream
  - compaction and out-of-order simulation (as test fixtures)

## Deliverable

Create `docs/plans/2026-03-05-phase-0-5-gap-table.md` containing:

- The primary gap table (Acceptance + Test matrix items)
- A short “current status summary” (counts of ✅/🟡/❌ by section)
- A “worklist” derived from sorting the ❌/🟡 items by prioritization rules above

