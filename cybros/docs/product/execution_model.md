# Execution Model

## Canonical Lifecycle

The authoritative sequence lives in `run_lifecycle.md`.

This document defines the runtime-selection rules that feed that lifecycle.

## Entry Points

The same execution model applies to:

- interactive conversations
- automations
- Cybros-originated follow-up work

Different entrypoints may provide different defaults, but they converge on one `RunDraft -> finalization -> immutable run` path.

## Runtime Selection

Every draft resolves these inputs before finalization:

- `AgentProgram`
- published contract fingerprint
- active healthy `AgentDeployment`
- effective permission preset
- `ExecutionTarget`
- provider credential
- runtime-governor facts

If any of those inputs becomes stale before finalization, Cybros must re-resolve explicitly or fail with a structured error.

## Agent Selection

### Interactive Default

Each conversation stores one top-level `AgentProgram`.

The default interactive path is the bundled external agent with bundled key `default`. There is no builtin conversation-agent runtime fallback.

Top-level interactive execution only proceeds through a materialized `ConversationRun`. If runtime resolution is reached without that run binding, Cybros fails with `cybros.agent_runtime_resolver.programmable_run_required` instead of constructing a local LLM fallback.

The composer footer should surface that selection directly.

Changing it updates `Conversation.agent_program_id` and affects future drafts only.

### Deployment Resolution

The user-facing selector chooses `AgentProgram`, not `AgentDeployment`.

Cybros resolves the active healthy deployment that matches the program's current published contract during planning.

If no active healthy deployment exists, Cybros should surface a stale-selection warning and block new draft materialization until the operator fixes the deployment or the user chooses another program.

Official local development and official compose wire the bundled default and forked custom paths through managed-local deployments that Cybros auto-launches from deployment-owned runtime config. Local development uses loopback endpoints; official compose binds the agent process on `0.0.0.0` inside the supervisor container and advertises the `agent_deployments` service address to the rest of the stack.

Unsupported external deployment topologies stay explicit and operator-managed.

### Config Namespacing

Conversation `agent_config` is interpreted through the selected program's contract namespace.

Switching agents does not clear unrelated config namespaces.

### Subagent Rule

Subagents remain owned by the top-level agent active for the turn that launched them.

Later conversation-level agent changes do not retroactively rewrite those decisions.

## Target Selection

### Canonical Field

Each conversation stores one `default_execution_target_id`.

User selection in the composer footer and accepted agent target proposals both converge on that field.

### Discovery And Proposal

Execution-target discovery is read-only:

- `execution_target.list`
- `execution_target.get`

Target switching is a separate mutation path:

- `execution_target.propose`

### Decision Vocabulary

Target switching reuses the shared policy outcomes:

- `allow`
- `confirm`
- `deny`

Default V1 behavior:

- same target: `allow`
- different visible target: `confirm` under `conservative` and `default`
- different visible target may become `allow` under `full_access` after validation
- invisible, inactive, unhealthy, or forbidden target: `deny`

`rejected` remains a runtime outcome after a confirmation is denied.

### Workspace Semantics

- a workspace always belongs to one execution location
- no implicit cross-location sync exists
- the same repo on two machines is treated as two workspaces

## Permission Presets

V1 exposes three product-level presets:

- `conservative`
- `default`
- `full_access`

They compile into Cybros-owned policy bundles. They do not replace hard validation, deployment checks, or target validation.

Changing a conversation preset affects future drafts only.

Automations default to `full_access`.

## Failure And Drift

If the selected deployment is unreachable, unhealthy, or host-failing:

- Cybros records a deployment runtime error
- work may park in durable `deployment_backoff`
- operators may repair or replace the deployment
- Cybros does not self-heal the deployment

Managed-local launch failures must still surface as deployment failures on the same canonical loop. They do not unlock a builtin fallback.

Transport replay, approval resume, and lost-reply recovery must follow the rules in `run_lifecycle.md` and `agent_rpc.md`.

## Public Surface Direction

The programmable boundary should remain explicit and stable:

- `conversation.settings.*`
- `conversation.config.*`
- `conversation.kv.*`
- `execution_target.*`

Implementation details may vary, but the product boundary should not collapse back into metadata patches or storage-level writes.
