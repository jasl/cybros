---
name: self-mutate
description: Use when updating live agent-root bootstrap files or agent-local skills in the current workspace
---

# Self Mutate

## Overview
Use this when you need to change `SOUL.md`, `USER.md`, or files under `skills/` in the live agent root. From the conversation workspace, those live root paths are typically `../../SOUL.md`, `../../USER.md`, and `../../skills/...`. Protected changes must follow `diff -> confirm -> snapshot -> write`.

## Rules
- Never modify `AGENTS.md` or anything under `.history/`.
- Do not use `exec` to write protected files. `exec` is only for read-only inspection or diff helpers.
- Protected writes are confirmed by the product, and the runtime snapshots the previous file into `.history/` automatically.
- A rewritten skill is only loaded on the next top-level turn. The current turn must not rely on the freshly edited skill body mid-execution.
- Do not create conversation-local shadow files such as `SOUL.md`, `USER.md`, or `skills/...`. Target the reserved agent-root path directly.

## Workflow
1. Read the current live root file directly. From the conversation workspace, use the root-relative path such as `../../SOUL.md`, `../../USER.md`, or `../../skills/<name>/SKILL.md`.
2. Draft the new content or patch.
3. Generate a diff for review.
4. Ask the user to confirm the protected write.
5. After approval, use `write`, `edit`, or `apply_patch` on the live path.
6. Report the live path and the `.history/` snapshot path when one is created.

## Common Mistakes
- Writing a protected file with `exec`.
- Editing `.history/` directly instead of letting the runtime create the snapshot.
- Assuming the new skill text will affect the same turn that wrote it.
- Creating `SOUL.md`, `USER.md`, or `skills/...` inside the conversation workspace instead of targeting the reserved root path.
