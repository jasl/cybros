# Protected Agent-Root Skill Installer Design

## Status

Approved follow-up design notes for adding a byte-preserving skill installation path on top of the approved agent-root workspace cutover in `docs/plans/2026-03-16-agent-root-workspace-design.md`.

This addendum narrows only the skill installation and layering model. It does not reopen the approved root/conversation/lane workspace model, memory model, branch snapshot rules, or approval-driven live acceptance rules from the main design.

## Goal

Add a first-class skill installation path that:

- installs remote or catalog skills without routing file contents back through LLM-authored `write.content`
- preserves the existing protected write boundary for `root/skills/**`
- keeps platform-owned skills and agent-local installed skills clearly separated
- preserves next-top-level-turn refresh semantics
- remains compatible with approval-driven live acceptance

## Problem Statement

The approved agent-root design intentionally allows protected mutation of `root/skills/**`, but that is not sufficient for safe installation from GitHub or a curated catalog.

If the installation path is:

1. fetch upstream text
2. ask the model to re-emit the file body
3. write the model-generated text into `root/skills/**`

then the install is semantically plausible but not byte-preserving. Small model rewrites can silently alter bullet structure, wording, scripts, frontmatter, or auxiliary assets. That is acceptable for hand-authored edits, but not for "install this upstream skill" behavior.

The missing primitive is not another prompt rule. The missing primitive is a runtime-managed installer that copies validated bytes from a source into the agent root after approval.

## Design Summary

The skill model is split into three different concepts:

- `system` layer: platform-owned built-in skills shipped by Cybros
- `catalog` layer: installable sources such as curated or experimental skill repositories
- `agent-local installed` layer: live skills under `<agent-root>/skills/<skill_name>/`

Only the first and third layers participate in runtime skill resolution.

The catalog layer is not a runtime precedence layer. It is a source of installable packages only.

To install a remote skill, the agent must use a new runtime-managed tool:

- `skills_catalog_list` for discovery from configured catalogs
- `skills_install` for protected installation or replacement

`skills_install` stages the source, validates the skill directory, computes hashes, prepares the approval payload, snapshots the previous installed version when replacing an existing agent-local skill, then atomically promotes the staged directory into `<agent-root>/skills/`.

At no point should the LLM reconstruct `SKILL.md` or any skill asset bytes before they are written to disk.

## Relationship To OpenAI Skills

The design intentionally borrows one idea from `references/openai-skills` and rejects another:

- borrow: keep `system` and `catalog` conceptually separate
- reject: do not let catalog directories participate in runtime skill precedence

The `references/openai-skills` repository uses `.system` for built-in Codex skills and `.curated` for installable catalog entries. That taxonomy is useful for distribution, but Cybros has stricter runtime governance requirements:

- platform skills and agent-local skills must have stable ownership boundaries
- protected writes must stay approval-gated
- branch snapshot semantics must remain conversation-memory-only
- runtime refresh must stay next-top-level-turn, not mid-turn

Therefore the "catalog" idea is adopted as a distribution concern, not as a runtime merge layer.

## Layer Model

### 1. System Layer

The system layer contains platform-owned skills that are always controlled by Cybros.

Recommended source layout:

```text
cybros/skills/
  .system/
    skill-installer/
      SKILL.md
```

This is a source-layout recommendation, not a new precedence rule. Cybros may keep the current `platform_skill_dirs` mechanism and simply point it at `Rails.root.join("skills/.system")`.

System-layer invariants:

- not writable by agents
- not writable by `skills_install`
- not overridable by agent-local skills
- participates in runtime skill inventory

### 2. Catalog Layer

The catalog layer is a list of installable sources. It may point at:

- a curated GitHub repo path such as `openai/skills:skills/.curated`
- an experimental catalog
- an internal mirror
- future signed catalogs

Recommended conceptual layout:

```text
skills/
  .curated/
  .experimental/
```

Catalog-layer invariants:

- never merged into runtime skill inventory directly
- used only by discovery and installation flows
- may be remote, mirrored, or cached
- configured at the operator/platform level, not by agent-owned mutable state

### Catalog Ownership

V1 catalog configuration is instance-owned operator configuration.

Recommended ownership rules:

- catalogs live in `RuntimeSetting` or another operator-owned runtime config surface
- agents may query catalogs through `skills_catalog_list`
- agents may not mutate catalog definitions through any agent tool
- agent guidance files and agent-local skills may recommend a catalog entry, but they may not redefine what a catalog points at

This keeps source discovery under the same trust boundary as other platform/runtime configuration.

### 3. Agent-Local Installed Layer

The live installed destination remains:

```text
<agent-root>/skills/<skill_name>/
  SKILL.md
  scripts/
  references/
  assets/
```

Agent-local invariants:

- belongs to one `Agent`
- mutable only through protected mutation surfaces
- participates in runtime skill inventory
- visible to all conversations under that same agent root

## Runtime Precedence And Collision Rules

Runtime skill resolution continues to merge:

1. system/platform skills
2. agent-local installed skills

Name collisions fail closed.

V1 rules:

- an agent-local installed skill may not shadow a system/platform skill
- `skills_install` must reject an attempted install that would create such a collision before approval
- generic runtime refresh must surface a stable error if the on-disk state somehow becomes invalid

The catalog layer has no precedence because it is not loaded into the runtime skill store.

## Tool Surface

### `skills_catalog_list`

`skills_catalog_list` is a read-only discovery tool.

Inputs:

- optional `catalog`
- optional `path`
- optional `query`

Outputs:

- catalog id
- source repo/ref/path
- display name
- installed status for the current agent
- optional short description when available

This tool replaces the need for the model to scrape GitHub pages just to answer "what can I install?".

### `skills_install`

`skills_install` is a protected mutation tool for agent-local skill installation.

Inputs:

- `source_kind=catalog|github`
- `catalog` and `catalog_entry`, or `repo/ref/path`
- optional `install_as`
- optional `replace`
- optional `expected_sha256`

Input rules:

- `replace` defaults to `false`
- if the destination skill already exists and `replace` is not explicitly `true`, the install fails before approval
- `expected_sha256`, when supplied, refers to the canonical package hash defined below

Outputs on success:

- `installed_name`
- `live_path`
- `source`
- `source_sha256`
- `installed_sha256`
- `snapshot_path` when replacing an existing agent-local skill
- `refresh_effective_on_next_top_level_turn=true`

Outputs on failure:

- stable error code
- source details
- no partial live install

`skills_install` is always protected. Approval is required even when ordinary workspace writes are broadly allowed.

### Canonical Package Hash

V1 must define one stable package-hash algorithm so approval payloads, provenance records, and live acceptance all compare the same value.

Recommended algorithm:

1. enumerate all regular files under the staged skill root
2. normalize every path to a slash-delimited path relative to the skill root
3. sort entries lexicographically by normalized relative path
4. compute per-file sha256 over raw file bytes
5. build a canonical JSON array of:
   - `path`
   - `byte_size`
   - `sha256`
6. compute `package_sha256 = sha256(canonical_json_bytes)`

Rules:

- `source_sha256` means the canonical package hash of the staged source
- `installed_sha256` means the canonical package hash of the live installed directory
- `expected_sha256`, when present, must match `source_sha256`

The system may also expose per-file hashes, but package-level verification must use this canonical package hash.

## Runtime Execution Ownership

The installer is a runtime capability, but bundled `claw` still needs a concrete execution path.

V1 rule:

- `skills_catalog_list` and `skills_install` must be real bundled-`claw` tool implementations
- they must be wired through the same `tool_executor` path as other `claw:*` tools
- they must not exist only as public tool schemas without a concrete `claw` implementation

This matters because Cybros exposes tools twice:

- as public runtime schemas and policy surfaces
- as bundled `claw` implementations selected by `implementation_ref`

Both layers must land together or live turns will advertise tools that cannot actually execute.

## Installer Execution Model

### Staging

`skills_install` must never write directly into `<agent-root>/skills/<name>` while still fetching or validating the source.

The runtime must:

1. resolve the source
2. fetch it into a staging directory
3. locate the requested skill root
4. validate that the root contains a valid `SKILL.md`
5. enumerate all regular files that belong to the skill
6. compute a deterministic manifest and sha256 digests

The live agent root is untouched until all preconditions pass and approval succeeds.

### Accepted Source Types

V1 supports:

- configured catalog entries
- direct GitHub repo/ref/path installs

Fetch strategy:

- public repos: zip download is preferred
- auth failures or private repos: git sparse checkout fallback is allowed

### Validation Rules

The staged skill must fail closed on:

- missing `SKILL.md`
- path traversal
- symlinks that escape the staged skill root
- non-regular files
- unexpected empty install
- `install_as` that is not a single path segment
- collision with a system/platform skill name
- mismatch between computed source hash and `expected_sha256`

V1 may allow arbitrary regular files under the skill root, but must preserve them exactly.

### Install Identity Rules

The destination identity is:

- `install_as` when provided
- otherwise the basename of the requested source path

V1 must fail closed when:

- the resolved destination name is invalid
- the destination name collides with a system/platform skill
- the destination already exists and `replace != true`

## Approval Workflow

The intended install workflow is:

1. the agent discovers a catalog entry or direct repo path
2. the agent calls `skills_install`
3. the runtime stages and validates the source
4. the runtime prepares an approval payload that includes:
   - source repo/ref/path
   - destination skill name
   - file count
   - changed file summary
   - source hash
   - whether an existing agent-local skill will be replaced
5. the product approval gate runs through the shipped path
6. only after approval does the runtime snapshot and promote

The harness may programmatically drive the approval path in tests, but it may not bypass or disable it.

## Snapshot And Promotion Semantics

### New Install

If the destination skill name does not exist in `<agent-root>/skills/`:

- no snapshot is required
- the staged directory is atomically promoted into the live destination

### Replacement Of An Existing Agent-Local Skill

If the destination already exists as an agent-local skill:

- the runtime snapshots the existing live directory before replacement
- the snapshot path lives under `root/.history/skills/<skill_name>/<timestamp-or-version>/`
- the snapshot is runtime-managed and read-only to the agent
- only after the snapshot succeeds may the staged directory replace the live one

If the snapshot fails, the install fails and the live skill stays untouched.

### Atomicity

Promotion must be atomic from the perspective of later turns:

- build in staging
- snapshot old version if needed
- move staged directory into place
- mark skills inventory dirty

The runtime must not leave a partially copied live skill tree.

## Provenance Metadata

Each installed agent-local skill should have runtime-managed provenance metadata, for example:

```text
<agent-root>/.state/skills/<skill_name>.json
```

Suggested fields:

- `skill_name`
- `source_kind`
- `repo`
- `ref`
- `path`
- `catalog`
- `catalog_entry`
- `source_sha256`
- `installed_sha256`
- `installed_at`
- `approved_by`
- `snapshot_path`

This metadata is not part of the skill package itself and must not be agent-writable.

## Protected Boundary Rules

### Allowed

- `skills_install` may create or replace `<agent-root>/skills/<skill_name>/`
- protected file mutation surfaces may still edit existing agent-local skills by hand under confirmation and snapshot rules
- the agent may read system skills, agent-local skills, and history entries

This preserves the approved agent-root behavior where an agent may hand-author or manually edit its own local skills. The stricter rule in this addendum is narrower:

- if the desired outcome is "install this external/catalog skill as published", the flow must use `skills_install`
- generic file mutation remains a manual authoring/editing path, not an external installation path

### Denied

- `skills_install` may not write into system/platform skill source directories
- `skills_install` may not write outside the resolved agent root
- `exec` may not perform direct mutation of protected skill paths
- agents may not write `.history/**` or installer provenance metadata directly
- remote or catalog skill installation may not be satisfied by generic `write`, `edit`, or `apply_patch` over fetched remote content

### Why This Preserves The Protected Write Boundary

The boundary is not "the model may never cause a skill change".

The boundary is:

- skill changes must go through runtime-known mutation surfaces
- those surfaces must understand path scope
- those surfaces must honor confirmation and snapshot rules
- those surfaces must produce auditable results

`skills_install` satisfies that contract. A shell-based `curl > ../../skills/...` path does not.

The same applies to "fetch upstream text, then reconstruct the files with `write`". That remains an editable-content workflow, not an installation workflow, and must not be treated as successful remote installation.

## Refresh Boundary

The approved agent-root workspace rule remains unchanged:

- the currently running turn keeps the skill inventory it started with
- successful installs become visible no later than the next top-level prompt assembly for the same agent
- mid-turn self-visibility is not required

The runtime must mark the agent skill inventory dirty after successful promotion and rebuild the merged store before the next top-level turn.

## Branch And Conversation Semantics

Skill installation is root-scoped, not conversation-scoped.

Therefore:

- a newly installed skill is visible to all conversations under the same agent after refresh
- branching a conversation does not copy or snapshot skills
- branch snapshot semantics remain limited to conversation memory as already approved

This is intentional. If the product later wants branch-scoped experimental skills, that requires a different concept such as agent fork or staged root overlays.

## Failure Modes

### Approval Denied

If approval is denied:

- the staged area is discarded
- no live mutation occurs
- no dirty refresh marker is written

### Snapshot Failure

If replacement snapshotting fails:

- the install fails
- the previous live skill stays in place
- no partial replacement is visible

### Promote Failure

If promotion fails after snapshot creation:

- the runtime surfaces a stable install failure
- the old live version must remain or be restored before returning failure
- the snapshot remains as audit evidence

### Hash Mismatch

If `expected_sha256` is provided and does not match the staged source:

- the install fails before approval

### Invalid Skill Layout

If the source lacks a valid skill root:

- the install fails before approval

## Live Acceptance Requirements

The skill installer feature is not complete until real-model live acceptance covers:

1. catalog listing
2. install a public catalog skill through the real approval path
3. install a direct GitHub repo/path through the real approval path
4. verify installed hash equals staged source hash
5. verify next-top-level-turn refresh exposes the new skill
6. verify a subsequent conversation successfully uses the installed skill
7. replace an existing agent-local skill and create a `.history/skills/**` snapshot
8. reject install attempts that collide with a system/platform skill
9. reject direct `exec` mutation attempts against protected skill paths

## Recommended V1 Shape

For V1, the smallest coherent product slice is:

- ship one system skill: `skill-installer`
- ship one read-only tool: `skills_catalog_list`
- ship one protected mutation tool: `skills_install`
- keep existing protected file mutation surfaces for manual edits to already-installed agent-local skills
- keep platform > agent-local fail-closed collision semantics

This solves the integrity problem without reopening the larger agent-root workspace design.
