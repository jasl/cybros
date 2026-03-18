# Claw Workspace Env Overlay Design

## Status

Draft on 2026-03-18, pending final review.

## Problem

The bundled `claw` runtime currently executes shell commands through `/bin/sh -lc` in the conversation working directory, but it does not load any workspace-owned environment overlay before spawning that subprocess.

That causes two practical problems:

- developer shell setup such as `rbenv` may not be available inside `claw` command executions because the runtime does not read interactive shell startup files
- the only current workaround is to hardcode wrappers or mutate host-level process state, which is awkward for agent-driven iteration and self-repair

The recent failure mode was not just “missing `.zshrc`”. The runtime ended up with a mixed Ruby environment, where system Ruby and `rbenv` Bundler state were partially combined. The design therefore needs a runtime-local, repeatable, file-backed environment overlay for `exec`.

## Goals

- let `claw` load workspace-defined environment overlays automatically for each `exec` call
- keep the effect local to the spawned shell subprocess rather than mutating the long-lived `claw` Rails process
- support two scopes only: shared `agent_root` defaults and current `lane` overrides
- make env changes take effect on the very next `exec` call without restarting `claw`
- allow the agent to mutate the env overlay files, but only through normal protected write flows with approval
- preserve branch isolation so one lane cannot silently change another lane's shell environment
- keep env parsing and warning behavior non-fatal so malformed overlay files do not block unrelated command execution

## Non-Goals

- no conversation-wide env scope
- no automatic mutation of the host shell or parent terminal environment
- no process-wide `ENV` mutation inside the running `claw` service
- no new database-backed env store in this pass
- no special “promote env” tool; promotion from lane to root remains an ordinary file edit workflow
- no automatic exposure of env values in transcript output or tool metadata

## Core Decision

`claw` gains a per-`exec` workspace env overlay layer.

For every `exec` invocation, the runtime will:

1. start from the current `claw` process environment
2. read zero or more approved env overlay files from `agent_root` and the current `lane`
3. merge those overlays in a fixed precedence order
4. pass the merged environment only to the spawned shell subprocess

The running `claw` process will not mutate its own `ENV`, and non-`exec` tools will not automatically consume workspace env overlay files.

## Scope Model

Only these scopes participate:

- `agent_root`
- `lane`

The effective file search order is:

1. `<agent_root>/.env`
2. `<agent_root>/.env.agent`
3. `<lane_path>/.env`
4. `<lane_path>/.env.agent`

Later files override earlier files.

`conversation_path` is intentionally excluded even though `cwd` remains the conversation directory. This avoids cross-branch conflicts inside the same conversation.

`lane` is the only branch-local env scope because it matches the existing DAG isolation model.

## File Semantics

The runtime should treat `.env` as a compatibility format and `.env.agent` as the recommended agent-owned write target.

Recommended operator behavior:

- human-managed app or repo configuration continues to live in `.env` when needed
- agent-managed execution fixes such as `PATH`, `RBENV_ROOT`, `RUBYOPT`, or `BUNDLE_GEMFILE` should prefer `.env.agent`
- a lane may first test settings in its local `.env.agent`, then copy stable values into `agent_root/.env.agent`

No lane-specific auto-promotion exists. Promotion is an explicit file edit.

## Parsing Rules

The parser should accept a dotenv-style safe subset:

- `KEY=VALUE`
- `export KEY=VALUE`
- `unset KEY`
- quoted or unquoted values
- `KEY=` meaning the variable is set to the empty string

The parser should not evaluate shell expansions, command substitutions, or arbitrary code.

`unset KEY` removes an inherited variable from the spawned subprocess environment. A later file may still set that same key again through normal precedence rules.

If a file is missing, it is silently ignored.

If a file is malformed:

- that file is ignored
- the command still runs
- successful lower-priority and higher-priority files still participate normally

This keeps env overlay behavior helpful rather than brittle.

## Execution Semantics

The current `cwd` stays unchanged and remains the conversation directory.

The env overlay only affects the spawned subprocess environment for `exec`.

This means:

- `read`, `write`, `edit`, `apply_patch`, memory, skills, and web tools do not load overlay env files automatically
- `exec` sees the merged environment immediately on the next invocation after a file change
- already-running long-lived services are unaffected until a new subprocess is spawned

## Protection And Approval Model

The following files are protected paths:

- `<agent_root>/.env`
- `<agent_root>/.env.agent`
- `<current_lane_path>/.env`
- `<current_lane_path>/.env.agent`

Mutating any of those files through `write`, `edit`, or `apply_patch` requires confirmation.

Confirmed writes to protected `.env*` files should also receive the same runtime-managed `.history` snapshot treatment used for other confirmable agent-root files. This keeps env experimentation reversible.

Shell-based indirect mutation through `exec` remains denied, including redirection, `tee`, `sed -i`, and similar patterns.

The following writes are denied rather than confirmable:

- any `.env` or `.env.agent` under `conversation_path`
- any `.env` or `.env.agent` under a non-current lane path

This yields a clear operating model:

- current lane env edits: allowed with approval
- agent-root env edits: allowed with approval
- conversation-scope env edits: denied
- cross-lane env edits: denied

## Failure Handling

Env overlay loading is best-effort.

Failure policy:

- missing file: ignore
- unreadable or malformed file: ignore that file and continue
- no valid overlay files: run with inherited process environment only

The command result should not fail solely because one overlay file could not be parsed.

## Observability

`exec` results should expose non-sensitive metadata about overlay behavior without returning env values.

Recommended metadata fields:

- `env_overlay_applied`
- `env_files_loaded`
- `env_files_ignored`
- `env_parse_warnings`

Warnings should contain only file paths and safe error summaries.

Warnings should not be injected into command `stdout` or `stderr`; they belong in structured metadata only.

## Prompt And Agent Guidance

The runtime behavior does not require a new tool.

However, bundled `claw` prompt or skill guidance should eventually steer the agent toward this workflow:

- prefer `.env.agent` over `.env` for agent-authored execution fixes
- test risky env changes in the current lane first
- promote stable settings to `agent_root/.env.agent` only after validation

That guidance is secondary to the runtime contract and can land after the underlying execution semantics are correct.

## Testing Strategy

Coverage should focus on immediate effect, branch isolation, and path protection.

### `claw` runtime tests

Add or extend tests around `agents/claw/test/integration/rpc_contract_test.rb` to cover:

- `exec` loads `agent_root` and current `lane` env overlays
- lane values override root values
- `unset KEY` clears inherited env for the spawned subprocess
- missing files are ignored
- malformed files are ignored while the command still runs
- metadata reports loaded and ignored files without leaking values
- editing `.env.agent` changes the next `exec` result immediately

### Main app policy tests

Extend `cybros/test/lib/cybros/agent_runtime_resolver_test.rb` to cover:

- current lane `.env*` writes require confirmation
- agent-root `.env*` writes require confirmation
- shell mutation attempts against `.env*` are denied
- conversation-scope `.env*` writes are denied
- non-current lane `.env*` writes are denied
- protected `.env*` writes still route through snapshot-capable file mutation paths rather than `exec`

### End-to-end acceptance test

Add one realistic workflow test for the motivating scenario:

- set lane-local env overrides for Ruby pathing such as `RBENV_ROOT` and `PATH`
- verify `exec` resolves the intended Ruby executable or version
- copy the stable settings into `agent_root/.env.agent`
- verify a fresh lane inherits the shared root behavior without lane-local overrides

## Implementation Sequence

The work should land in this order:

1. Add a small env overlay loader in `agents/claw` plus direct parser tests.
2. Wire the loader into `WorkspaceTools#exec` and return non-sensitive overlay metadata.
3. Add `claw` integration tests that prove immediate effect and lane-over-root precedence.
4. Extend protected-path policy in the main app for `.env` and `.env.agent` across `agent_root`, current lane, conversation path, and non-current lanes.
5. Add one realistic end-to-end acceptance test for the `rbenv`/Ruby path scenario.
6. Only after the runtime and policy semantics are stable, add prompt or skill guidance encouraging `.env.agent` usage.

This sequence keeps the behavior contract ahead of policy copy and keeps prompt guidance last so the agent is never taught to use a capability before the runtime safely enforces it.

## Review Checklist

Before implementation begins, confirm that the design still satisfies these constraints:

- env overlays are `agent_root + current_lane` only
- conversation-scope env files are not part of the runtime contract
- the running `claw` service process does not mutate its own `ENV`
- overlay files can explicitly `unset` inherited variables when needed
- malformed env files do not block command execution
- no env values are exposed through transcript-visible metadata
- protected writes are confirmable only for current lane and agent root
- protected `.env*` writes preserve `.history` snapshots
- cross-lane and conversation-scope env writes are denied
