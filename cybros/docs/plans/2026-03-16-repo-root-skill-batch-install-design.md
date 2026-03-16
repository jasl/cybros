# Repo-Root Batch Skill Install Design

## Status

Approved follow-up design notes for extending the protected skill installer so a GitHub repo root can resolve to a batch install of all discovered skills.

This addendum narrows only the repo-root installation behavior. It does not reopen the approved protected write boundary, branch promotion rules, next-top-level-turn refresh rules, or the single-skill installation semantics already approved in `docs/plans/2026-03-16-agent-root-skill-installer-design.md`.

## Goal

Allow a user request like:

- "Help me install `https://github.com/obra/superpowers`"

to succeed through the product installer happy path without forcing the agent to reconstruct skill files through model-authored `read` and `write` loops.

The intended behavior is:

- the agent should be able to call one protected tool
- the tool should treat a repo root as "install all discovered skills from this repo"
- the install should use one approval and one atomic commit point
- the agent should not need to author or rewrite `SKILL.md`, `references/`, `scripts/`, or other package bytes

## Problem Statement

The current `skills_install` contract treats GitHub installs as a single-skill operation:

- `repo + path` means install that one staged skill root
- `repo` without `path` resolves to the repo root itself

That works for a repo that is itself one skill package, but it fails for real multi-skill repositories such as `obra/superpowers`, where skills live under subdirectories like:

- `skills/<name>/SKILL.md`
- `skills/.system/<name>/SKILL.md`

Today, a repo-root install attempt correctly fails with `cybros.skills_install.invalid_skill_root` because the repo root does not contain a `SKILL.md`.

That behavior is valid under the old contract, but it is not the desired user experience. The product should be able to interpret a repo root as a batch-install source and perform the discovery itself, instead of making the agent:

1. inspect the repo
2. infer candidate skill paths
3. loop over multiple installs
4. or, worse, fetch bytes and reconstruct the skill files through ordinary file tools

## Design Summary

`skills_install` remains the only protected installation tool. No repo-specific companion tool is added.

The tool gains a second GitHub mode:

- `single_skill` mode: `source_kind=github`, `repo`, and `path` are present
- `repo_root_batch` mode: `source_kind=github`, `repo` is present, and `path` is absent

In `repo_root_batch` mode, the installer:

1. stages the repo once
2. discovers all candidate skill roots
3. validates the full candidate set
4. prepares one approval payload that describes the full batch
5. after approval, atomically installs the entire batch into `<agent-root>/skills/`

The user-facing default is "install all discovered skills from this repo."

## Non-Goals

This design does not:

- add a new `skills_install_repo` tool
- require the agent to ask the user which skill to install when the repo is clearly a multi-skill repo
- support partial success within a repo-root install batch
- allow repo-root installs to silently skip invalid or colliding skills
- add a new compatibility mode for model-authored byte reconstruction

## Tool Contract

### `skills_install`

The tool keeps its existing name and remains the single protected installer surface.

Inputs continue to include:

- `source_kind=catalog|github`
- `catalog` and `catalog_entry`, or `repo/ref/path`
- optional `install_as`
- optional `replace`
- optional `expected_sha256`

GitHub mode is extended as follows:

- if `path` is present, the call is a single-skill install
- if `path` is absent, the call is a repo-root batch install

For repo-root batch installs:

- `install_as` is not accepted
- `replace` defaults to `false`
- the tool installs all discovered skills from the repo
- one approval covers the full batch
- one atomic promotion covers the full batch

### Success Shape

The success response should normalize around a batch result, even when only one skill is installed.

Recommended top-level fields:

- `mode=single_skill|repo_root_batch`
- `source_kind`
- `repo`
- `ref`
- `refresh_effective_on_next_top_level_turn=true`
- `installed_count`
- `installed_skills`

Each `installed_skills[]` entry should contain:

- `installed_name`
- `source_path`
- `live_path`
- `source_sha256`
- `installed_sha256`
- `snapshot_path` when replacing an existing agent-local skill
- `provenance_path`

### Failure Shape

Repo-root batch installs fail closed.

Failure output must include:

- stable error code
- repo/ref context
- any candidate path or collision detail needed to explain the failure
- no partial live install

## Discovery Rules

Repo-root batch discovery must be deterministic and finite.

### Phase 1: Preferred Layouts

First, scan conventional multi-skill layouts:

- `skills/*/SKILL.md`
- `skills/.system/*/SKILL.md`

Generalized rule:

- start from `skills/`
- allow at most two nested directory segments before `SKILL.md`

This covers:

- `skills/verification-before-completion/SKILL.md`
- `skills/.system/skill-installer/SKILL.md`

### Phase 2: Fallback Scan

Only if phase 1 yields zero candidates:

- scan the repo root with a finite fallback search
- accept only `SKILL.md` files whose parent directory is within two nested directory segments of the repo root

The fallback exists for unusual repositories, but it should not override the conventional `skills/` layout when that layout already exists.

### Candidate Ordering

Candidates are ordered lexicographically by normalized repo-relative skill root path.

That ordering must be used consistently for:

- validation
- approval payload display
- install execution order
- provenance emission
- live acceptance expectations

## Candidate Identity Rules

Each discovered candidate resolves to one concrete install target.

For repo-root batch mode:

- the install name defaults to the basename of the skill root directory
- `install_as` is not available

Additional tightening:

- the skill name declared in `SKILL.md` must match the skill root basename
- if they differ, the full batch fails

This keeps repo-root installs mechanical and predictable.

## Batch Validation Rules

The full batch must validate before approval.

Any of the following causes the entire batch to fail:

- no candidate skills discovered
- a candidate root is missing `SKILL.md`
- a candidate contains invalid entries such as symlinks, non-regular files, or path escapes
- any resolved install name is invalid
- two candidates resolve to the same install name
- two candidates declare conflicting skill names
- a candidate collides with a platform/system skill name
- a candidate collides with an already-installed agent-local skill while `replace=false`
- any manifest or hash generation step fails

There is no partial success mode in V1.

## Approval Model

Repo-root batch install uses one approval.

The approval payload should include:

- `mode=repo_root_batch`
- source repo/ref
- discovered skill count
- an ordered list of candidate installs

Each candidate summary should include:

- install name
- source path
- file count
- canonical package hash
- whether it would replace an existing installed skill

Approval is still mandatory even when ordinary workspace writes are broadly allowed.

## Atomic Snapshot And Promotion

After approval:

1. create all required staging and temp destinations
2. create snapshots for every existing agent-local skill that will be replaced
3. if any snapshot fails, abort the full batch without mutating the live install set
4. promote all staged skills into the live agent root in deterministic order
5. if any promotion fails, roll back the full batch to the pre-approval state

This preserves the invariant:

- either none of the batch becomes live
- or the full batch becomes live

## Provenance

Provenance remains per installed skill, but repo-root batch installs should retain batch context.

Recommended provenance shape additions:

- `install_mode=repo_root_batch`
- `batch_repo`
- `batch_ref`
- `batch_position`
- `batch_size`

This keeps each installed skill independently auditable while preserving the fact that it arrived through one repo-root approval.

## Prompting And Agent Behavior

The product should bias the agent toward the protected installer happy path without attempting to ban all fallback behavior.

### Intended Agent Path

For a prompt like:

- "Help me install `https://github.com/obra/superpowers`"

the intended behavior is:

1. normalize the URL to `repo=obra/superpowers`
2. call `skills_install` without `path`
3. let the tool discover and install all repo skills

The agent should not need to:

- scrape the repo tree manually
- emit a loop of ordinary file mutations to reconstruct the package bytes
- ask the user which skill to install when repo-root batch semantics already answer that question

### Guidance Text

The `skills_install` tool description and the built-in `skill-installer` system skill should both state that:

- a GitHub repo root is a valid input
- repo-root input means "install all discovered skills from this repo"
- the protected installer path is preferred over model-authored byte reconstruction

This does not prevent the agent from choosing another path in exceptional cases, but it makes the product happy path obvious.

## Testing And Acceptance

### Deterministic Tests

Add or extend tests for:

- repo-root discovery under conventional layouts
- fallback discovery with limited depth
- stable candidate ordering
- full-batch validation failures
- full-batch collision failures
- atomic batch promotion and rollback
- per-skill provenance in a batch install

### Claw And Runtime Contract Tests

Lock:

- `skills_install` repo-root batch schema and execution routing
- approval payload generation for batch installs
- next-top-level-turn refresh exposing all newly installed skills
- continued availability of `skills_load` and `skills_read_file`

### Live Acceptance

Live acceptance must cover:

- local multi-skill repo root installs
- repo-root install failure on invalid candidates
- repo-root install failure on collisions
- repo-root install success with one approval and all skills visible on the next top-level turn

Real-environment validation may use `development` directly. If prior installed skills would invalidate the batch scenario, they may be removed manually before the proof run.

### Real Proof

The final proof should include a real repo-root install against `https://github.com/obra/superpowers` and verify:

- the repo root call uses `skills_install`
- the discovered batch installs successfully
- the installed bytes match upstream for at least one sampled installed skill
- a later conversation successfully uses at least one installed skill

## Recommended V1 Shape

The smallest coherent product slice is:

- extend `skills_install` to accept repo-root GitHub inputs
- discover all candidate skills from that repo
- validate the full batch before approval
- approve once
- atomically install the full batch
- refresh the skill inventory on the next top-level turn
- prove the behavior in deterministic tests and real `development` conversations
