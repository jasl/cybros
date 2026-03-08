# Migration Alignment

This document maps the current codebase to the runtime rebaseline target.

## Immediate Mismatches

### 1. Conversation Is Metadata-Driven

Current state:

- conversations are created with `metadata["agent"]["agent_profile"]`
- there is no first-class `agent_program` relation
- there is no first-class execution target relation

Relevant files:

- `app/controllers/conversations_controller.rb`
- `app/models/conversation.rb`
- `db/schema.rb`

Target:

- `Conversation` references `agent_program`
- `Conversation` references a default `execution_target`
- metadata is no longer the primary product model

### 2. ConversationRun Is Too Thin

Current state:

- run state tracks `dag_node_id` and lifecycle only
- no agent snapshot
- no execution-target snapshot

Relevant files:

- `app/models/conversation_run.rb`
- `db/schema.rb`

Target:

- run snapshot stores the effective agent, target, provider credential, and policy/governor inputs

### 3. AgentProgram Is Only A Local Directory Wrapper

Current state:

- local path plus `runtime_surface` snapshot
- no setup/install lifecycle
- no healthcheck lifecycle
- no config-schema contract

Relevant files:

- `app/models/agent_program.rb`
- `app/services/agent_programs/loader.rb`
- `app/services/agent_programs/creator.rb`

Target:

- agent program becomes a first-class source package with manifest and agent-defined config contract ownership

### 3.5. AgentDeployment Does Not Exist Yet

Current state:

- there is no entity representing "connectable deployment for this agent program"
- registration, transport binding, and inspection are not modeled explicitly

Target:

- introduce `AgentDeployment` as the runnable and connectable unit for `AgentProgram`

### 3.6. Draft And Run Semantics Are Mixed Together

Current state:

- the runtime treats queued run records as both planning and execution artifacts
- target changes and approval waits do not have a distinct pre-run planning layer

Target:

- introduce explicit draft semantics before immutable `ConversationRun` materialization

### 4. Workspace Exists Only As Runtime Context

Current state:

- runtime resolver injects `cwd/workspace_dir` from `Rails.root` or `Dir.pwd`
- workspace is not a product object

Relevant files:

- `lib/cybros/agent_runtime_resolver.rb`

Target:

- workspace is selected through an execution target

### 5. Nexus/Conduits Semantics Need Re-baselining

Current state:

- Mothership and Nexus evolved in parallel
- Conduits concepts were designed before the deployment-oriented programmable-agent model was defined clearly

Relevant files:

- `mothership/app/models/conduits/facility.rb`
- `mothership/app/models/conduits/directive.rb`
- `nexus/docs/protocol/conduits_api_openapi.yaml`

Target:

- protocol semantics explicitly represent execution-only concerns
- Cybros product models remain canonical; Conduits adapts to them

### 6. State Classes Are Not Explicit Enough

Current state:

- conversation metadata risks absorbing unrelated product state
- settings, operational KV, memory, and internal state are not sharply separated

Target:

- state classes are explicit and typed
- public settings and per-conversation agent config are distinct from shared KV
- run snapshots remain immutable

### 7. Automation Needs Core Domain Support

Current state:

- automation exists conceptually but is not yet part of the rebaseline data model

Target:

- automation binds to agent and execution target primitives in Phase 1

### 8. Runtime Governance Is Not First-Class Yet

Current state:

- the current provider model still conflates provider entry and credential record
- there is no credential-scoped provider limiter model
- job throughput is still mostly an implementation default
- execution resource protection is not modeled as location/target quota policy

Relevant files:

- `app/models/llm_provider.rb`
- `app/controllers/system/settings/llm_providers_controller.rb`

Target:

- the LLM domain separates `ProviderSpec` and `ProviderCredential`
- v1 keeps one active credential per `provider_key`
- provider rate limiting is attached to each provider credential
- job throughput is operator-tunable in dedicated instance-scoped runtime settings
- execution quotas are modeled on `ExecutionLocation` with optional `ExecutionTarget` override

### 9. Permission Behavior Is Still Hidden In Resolver Defaults

Current state:

- approval behavior is largely implied by runtime resolver defaults such as `ConfirmAll`
- there is no first-class conversation-scoped top-level agent selector
- there is no first-class conversation-scoped permission preset
- automation does not yet carry an explicit non-interactive permission default

Relevant files:

- `lib/cybros/agent_runtime_resolver.rb`
- `app/views/conversations/show.html.erb`
- `app/controllers/conversations_controller.rb`

Target:

- `Conversation` stores an explicit `agent_program_id` used by future turns
- `Conversation` stores an explicit `permission_mode`
- `Automation` stores an explicit `permission_mode` and defaults to `full_access`
- conversation `agent_config` remains namespaced store instead of being cleared on agent changes
- Cybros compiles that preset into a runtime policy bundle and snapshots the effective result per draft and run

## Recommended Implementation Sequence

Use `docs/plans/README.md` as the task-level execution order. The sequence below is only a repository-level cutover grouping for code ownership, not a compatibility-preserving migration recipe.

1. Add new product docs and freeze old product docs.
2. Add `AgentDeployment` as a first-class connectable model and define explicit registration flow.
3. Add the new execution-domain tables and relations.
4. Define draft finalization and immutable `ConversationRun` materialization before controller cutover.
5. Refactor conversation creation and run creation to use first-class relations.
6. Add conversation public settings, agent config, and shared KV APIs.
7. Rework `AgentProgram` into a source-package model and keep runtime connectivity, inspection, and health on `AgentDeployment`.
8. Rebaseline runtime resolver and execution context assembly on top of first-class execution targets.
9. Add automation domain primitives bound to agent and execution target.
10. Add explicit conversation-level agent selection, permission presets, and execution-target selection before the composer runtime-selection UI becomes user-facing.
11. Add runtime governance primitives for provider limits, job throughput, and execution quotas.
12. Re-align Conduits and Nexus protocol semantics.
13. Update UI and tests after the domain model is stable, including Playwright E2E coverage for composer runtime selectors, settings-management flows, and create -> run -> audit business flows.

## Destructive Refactor Rule

When the old implementation conflicts with the new product model:

- prefer deletion over compatibility layers
- prefer schema rewrite over adapter accumulation
- prefer a smaller clean API over preserving legacy call sites
