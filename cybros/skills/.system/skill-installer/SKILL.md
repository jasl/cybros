---
name: skill-installer
description: Use when asked to install or replace a remote or catalog skill
---

# Skill Installer

## Overview
Use this when the user wants an upstream skill installed as published, not manually rewritten. The runtime owns that workflow so the installed bytes stay aligned with the source package.

## Rules
- Use `skills_catalog_list` to discover installable skills from configured catalogs.
- Use `skills_install` to install or replace a published skill from a catalog entry or GitHub source.
- When the user gives a GitHub repo root and no explicit skill path, call `skills_install` with `repo` and no `path` first.
- Repo-root GitHub installs default to installing all discovered skills from that repo in one protected batch.
- Do not fetch upstream skill files and reconstruct them with `write`, `edit`, or `apply_patch`.
- Do not use `exec` to mutate `skills/**`; protected installs must go through the runtime-managed installer.
- Installing or replacing a skill requires approval.
- A successful install becomes available on the next top-level turn, not mid-turn.
- System/platform skill names are reserved and cannot be replaced by agent-local installs.

## Workflow
1. Identify the source.
2. If the user wants a catalog skill, call `skills_catalog_list` first.
3. If the user gave a GitHub repo root, prefer one direct `skills_install` call with that `repo` and no `path` instead of manually enumerating files or asking the user to choose one skill by default.
4. Call `skills_install` with the exact source details and `replace=true` only when the user explicitly wants to replace an existing agent-local skill, or when rerunning the same install requires replacing already-installed agent-local copies.
5. Only fall back to explanation or follow-up questions when the protected installer reports that no installable skills were discovered or that the full batch failed validation.
6. After approval, report the installed skill names, source hashes, installed hashes, and snapshot paths when replacements created them.

## Common Mistakes
- Treating a remote install like manual file authoring.
- Writing `SKILL.md` content by hand after reading a GitHub page or fetched text.
- Asking the user to pick one skill from a repo-root multi-skill repository when the protected installer can batch-install the whole repo.
- Assuming a newly installed skill is usable in the same turn that installed it.
