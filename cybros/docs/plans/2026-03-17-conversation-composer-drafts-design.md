# Conversation Composer Drafts Design

**Problem**

The conversation composer currently mixes two different concerns:

- persisted conversation defaults (`Conversation.permission_mode`, `Conversation.metadata["llm"]["model_ref"]`)
- the user's in-progress composer state on the page

That coupling forces `permission_mode` changes through `PATCH /conversations/:id -> redirect -> show`, which triggers a page-level Turbo visit. The visit currently causes visible flash, risks discarding unsent edits, and has already surfaced preserved-DOM regressions in sidebar state, markdown rendering, and realtime health UI.

The model picker avoids the page visit today, but it also does not persist immediately, so it still fails the intended UX.

**Goals**

- Keep composer edits and runtime-setting changes scoped to the composer instead of morphing the whole conversation page.
- Persist unsent composer content and runtime-setting changes on the server.
- Apply changed `permission_mode` and `model_ref` only to the next submitted turn, never the currently running turn.
- After a successful send, keep the chosen `permission_mode` and `model_ref` as the defaults for future turns.
- Preserve partially edited content across refreshes and reconnects.

**Non-goals**

- No reuse of `RunDraft` for UI draft state.
- No local-only storage as the source of truth.
- No optimistic mutation of the current turn's already-snapshotted runtime governors.
- No compatibility layer for the old hidden permission form.

## Decision

Introduce a conversation-scoped `composer_draft` persisted on `Conversation`, separate from execution-time `RunDraft`.

`RunDraft` remains the per-turn execution snapshot and continues to own deployment binding, approval, runtime governors, and current-turn behavior. `composer_draft` becomes the single source of truth for:

- unsent composer content
- the pending `model_ref`
- the pending `permission_mode`

The page renders from `composer_draft` first, falling back to conversation defaults only when no draft value exists.

## Data Model

Add `conversations.composer_draft jsonb not null default {}`.

Normalized shape:

```json
{
  "content": "draft text",
  "model_ref": "openai/gpt-5.4",
  "permission_mode": "conservative",
  "updated_at": "2026-03-17T12:34:56Z"
}
```

Rules:

- `content` is optional and trimmed only for validation/emptiness checks, not destructively rewritten while editing.
- `model_ref` is optional; when absent, UI falls back to the conversation's saved `metadata["llm"]["model_ref"]` or runtime resolver default.
- `permission_mode` is optional; when absent, UI falls back to `Conversation.permission_mode`.
- unknown keys are dropped during normalization.

## Server Behavior

Add a small composer-draft endpoint, for example:

- `PATCH /conversations/:id/composer_draft`

It updates only `composer_draft` and returns a narrow response (`204 No Content` or compact JSON), never a redirect to `show`.

On message send:

1. Resolve effective composer values from `composer_draft`.
2. Promote `model_ref` and `permission_mode` into the conversation's persisted defaults.
3. Use those promoted values when opening the next turn / planning the next run.
4. Clear only `composer_draft["content"]` after successful send.
5. Keep `composer_draft["model_ref"]` / `composer_draft["permission_mode"]` aligned with the promoted defaults, or normalize them away if they now match the conversation defaults.

This preserves "next turn only" semantics because current-turn execution already reads from its own snapshotted `RunDraft`, not from mutable composer state.

## Client Behavior

Replace the hidden permission form and page-level submit with composer-scoped autosave:

- text area changes debounce-save to `composer_draft.content`
- model picker changes debounce-save to `composer_draft.model_ref`
- permission picker changes debounce-save to `composer_draft.permission_mode`

The composer should display a lightweight save state (`saving`, `saved`, `error`) locally if needed, but it must not trigger a global page morph.

The message send path should continue using the current form submit for actual message creation, but it should source settings from the composer draft state rather than relying on a page-level settings redirect.

## Rendering Rules

Conversation show should render the composer from resolved draft state:

- text area initial value: `composer_draft.content`
- selected model: `composer_draft.model_ref` if present, else current conversation default
- selected permission mode: `composer_draft.permission_mode` if present, else `Conversation.permission_mode`

No other parts of the page should rerender when only the composer draft changes.

## Why Not `RunDraft`

Existing `RunDraft` is the wrong lifecycle and abstraction:

- it only exists once a turn starts
- it binds deployment, provider credential, approval, and expiry
- it represents "how this turn executes", not "what the user is currently editing"

Overloading it with unsent UI state would couple page editing with execution-time admission and approval semantics.

## Testing Strategy

Add regression coverage for:

- switching permission mode does not trigger page-level morph side effects
- switching model does not trigger page-level morph side effects
- unsent composer text survives runtime-setting changes and reload
- changed `permission_mode` persists and applies starting with the next turn only
- changed `model_ref` persists and applies starting with the next turn only
- after send, chosen settings remain the defaults for subsequent turns

## Recommended Rollout

Use a destructive cutover:

- add `composer_draft`
- move UI to autosave against the new endpoint
- remove the hidden permission form and redirect-based runtime-setting update path from the composer surface
- keep `Conversations::RuntimeSettingsUpdater` only for non-composer contexts if still needed elsewhere
