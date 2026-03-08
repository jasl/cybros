# Execution Model

## Run Flow

1. A run is triggered by a user action, automation, channel adapter, or agent-originated follow-up.
2. Cybros opens a durable run-planning draft.
3. Cybros loads the conversation's default agent program and default execution target.
4. Cybros resolves the agent program's active deployment.
5. Cybros resolves the selected provider credential and the applicable runtime governors for provider credentials, job throughput, and execution quota.
6. During the bounded planning session, the agent may read approved conversation state, inspect visible execution targets, and request staged public mutations or execution-target proposals through Cybros public APIs.
7. `turn.prepare` returns prompt fragments and workflow decisions for the current draft.
8. If the draft changed runtime selection, Cybros re-resolves deployment, provider, and governor facts against the updated draft.
9. Cybros resolves target-switch policy and validates target availability against the draft.
10. If target switching requires confirmation, Cybros persists the prepared draft result and blocks draft finalization in an approval state until a human confirms or rejects it. Staged draft mutations do not commit while the draft is parked.
11. Once final, Cybros atomically commits the staged draft operations, materializes immutable `ConversationRun`, snapshots the final run inputs, and performs the durable handoff for execution.
12. The programmable agent is invoked through the selected pinned agent deployment.
13. LLM calls must pass the selected provider credential limiter.
14. Dangerous or external actions are sent to Nexus against the selected execution target and must pass the resolved execution quota.
15. The run finishes with a durable run snapshot, transcript output, and audit trail.

The run snapshot should record:

- selected agent program
- effective permission mode
- agent deployment and deployment fingerprint
- deployment activation epoch
- execution target
- selected provider credential
- effective public settings
- effective `agent_config`
- `agent_config` schema fingerprint
- resolved runtime governor facts

## Agent Selection

### Default Rule

Each conversation has a default top-level `AgentProgram`.

The composer footer should expose that agent directly as a persistent conversation-level control.

Changing it updates `Conversation.agent_program_id` and affects future drafts and runs only.

### Deployment Rule

The user-facing selector chooses `AgentProgram`, not `AgentDeployment`.

Cybros continues to resolve the selected program's active deployment at planning time.

If the selected program has no active healthy deployment, the conversation should surface an explicit stale-selection warning and block new draft materialization until the operator fixes the deployment or the user selects another agent.

### Config Rule

Conversation `agent_config` should be treated as namespaced by a stable agent-program contract namespace.

Switching the conversation's top-level agent does not clear unrelated agent-config namespaces.

### Subagent Rule

Subagents are launched by the currently active top-level agent for that turn.

Later conversation-level agent-selector changes do not retroactively redirect or rewrite those subagent decisions.

## Target Selection

### Default Rule

Each conversation has a default execution target.

The composer footer should expose that target directly as a persistent conversation-level control.

Changing it updates `Conversation.default_execution_target_id` and affects future drafts and runs only.

### Agent Influence

The agent should be able to influence target selection as much as possible, but only through Cybros-managed APIs.

The intended model is:

- agent proposes
- the agent may first inspect visible targets through read-side public APIs
- Cybros validates
- policy decides
- confirm policies block and wait for human approval
- `ConversationRun` records the final choice only after the draft is finalized

If the accepted target changes runtime selection inputs, Cybros must re-resolve and re-pin the dependent runtime bindings before queueing.

### Discovery Rule

Execution-target discovery is a read path, not a mutation path.

The draft may expose visible target inventory through formal public APIs such as:

- `execution_target.list`
- `execution_target.get`

Those read APIs should return a curated summary for each visible target, including capability and policy context needed for agent planning.

### Policy Rule

Target switching should reuse the shared decision vocabulary already used elsewhere in Cybros:

- `allow`
- `confirm`
- `deny`

Default behavior in v1:

- same target: `allow`
- different visible target: `confirm` under `conservative` and `default`
- different visible target may become `allow` under `full_access` after normal visibility, health, and runtime validation checks succeed
- invisible, inactive, unhealthy, or forbidden target: `deny`

Policy may grant auto-switch inside trusted boundaries such as:

- same `trust_group`
- same `execution_location`
- same `sandboxed` posture
- non-sensitive capability sets

`rejected` remains a runtime outcome after a denied confirmation, not a policy result.

### History Rule

The same conversation may use different execution targets across runs.

This is safe because each `ConversationRun` snapshots the actual target used.

If an agent target proposal is accepted during draft finalization, Cybros should also update the conversation's canonical default execution target so the conversation footer, future drafts, and agent-visible state stay aligned.

## Workspace Semantics

- a workspace is always scoped to one execution location
- no automatic sync is assumed between locations
- the same repo on two machines is treated as two workspaces
- user or agent is responsible for choosing the right workspace

## Agent Deployment Failure

If the selected agent deployment is unreachable, unhealthy, or throws a host-level execution error:

- Cybros should raise a specific agent-deployment runtime error
- the current DAG node should enter retryable failure with durable `deployment_backoff`
- the operator may fix the deployment and retry
- the operator may also switch the conversation to another agent program and retry
- Cybros does not supervise or repair the deployment itself

## Retry And Resume Rule

- every turn-scoped call carries a stable `invocation_id`
- Cybros may replay the same `invocation_id` only against the same pinned deployment binding
- transport replay or interrupted remote retry opens a fresh bounded session for the same logical invocation
- approval resume reuses the persisted prepared draft result and does not send a second `turn.prepare`
- agent-to-Cybros mutation calls must carry a de-duplicated `operation_id`
- `operation_id` de-duplication must survive session replay for the same invocation
- if the pinned deployment changed or the prior outcome is unknowable, Cybros must fail the draft or run with a structured stale-or-unknown outcome error instead of guessing

## Runtime Governance Rules

### Provider Limits

- each configured provider credential has its own limiter
- v1 allows one active credential per `provider_key`
- provider limits are independent from background-job throughput
- provider limits apply to remote LLM API usage
- provider admission uses durable rate-budget reservation and settlement semantics
- each provider request must carry a durable provider-request identifier for recovery and observability

### Job Throughput

- ActiveJob/Solid Queue concurrency should be tunable by operators
- default throughput should be raised above the current conservative baseline
- job throughput is not the only governor in the system
- job throughput is instance-scoped runtime configuration, not an account preference

### Execution Limits

- code execution is protected by execution quotas
- the base quota is defined on `ExecutionLocation`
- `ExecutionTarget` may override that quota
- `AgentProgram` RPC calls are not separately rate-limited in v1
- execution admission uses durable capacity leases with expiry or heartbeat recovery
- each Nexus-bound execution request must carry a durable execution-request identifier for reconciliation

### Wait Semantics

- blocked work parks durably in runtime wait state instead of spinning in a worker
- wait reasons include `provider_limit`, `execution_quota`, and `deployment_backoff`
- parked waits do not count as admitted execution queue occupancy
- resume ordering should be stable and FIFO within one subject and wait reason
- `deployment_backoff` is a deployment-failure retry path, not a self-healing control loop

### Snapshot Versus Live State

- `RunDraft` and `ConversationRun` snapshot the resolved governor bindings and policy facts used for audit
- admission counters, reservations, leases, and backlog state are always live runtime state
- if operator policy changes invalidate an open draft, Cybros must re-resolve or fail the draft before materialization
- if live admission state cannot safely honor a previously queued plan, Cybros must park or fail with a structured runtime-governance error instead of silently bypassing the governor

## Automation Rule

Every automation must bind to an execution target. There is no implicit "run somewhere" behavior.

The automation domain model should land before the automation UI.

Each automation run resolves the currently active deployment at execution time and snapshots the resolved deployment facts.

Automation should default to `full_access` permission mode unless a stricter explicit override is introduced later.

`Automation` remains its own product aggregate even when it dispatches into an existing conversation-scoped execution path.

## Permission Presets

V1 should expose three conversation-scoped and automation-scoped permission presets:

- `conservative`
- `default`
- `full_access`

These presets compile into Cybros runtime policy bundles.

They do not replace hard validation, deployment binding checks, or execution-target validation.

Recommended semantics:

- `conservative`: readable actions may `allow`, dangerous actions default to `confirm`
- `default`: readable and in-boundary actions may `allow`, dangerous or boundary-crossing actions default to `confirm`
- `full_access`: actions that pass hard validation default to `allow`

Changing a conversation preset affects future drafts and runs, not an already materialized run.

The composer UI should surface the active preset next to model selection, the conversation agent selector, and the conversation target selector.

## API Direction

The product should expose public APIs in this shape:

- `conversation_settings_get`
- `conversation_settings_update`
- `conversation_config_get`
- `conversation_config_update`
- `conversation_kv_get`
- `conversation_kv_set`
- `conversation_kv_delete`
- `conversation_kv_list`
- `execution_target_list`
- `execution_target_get`
- `execution_target_propose`

The implementation may use other names, but the boundary should stay this clear.
