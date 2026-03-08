# Execution Model

## Run Flow

1. A run is triggered by a user action, automation, channel adapter, or agent-originated follow-up.
2. Cybros opens a mutable run-planning draft.
3. Cybros loads the conversation's default agent program and default execution target.
4. Cybros resolves the agent program's active deployment.
5. Cybros resolves the selected provider credential and the applicable runtime governors for provider credentials, job throughput, and execution quota.
6. `turn.prepare` may return prompt fragments, mutate public conversation state, and propose a different execution target while the draft is still open.
7. Cybros resolves policy and validates target availability against the draft.
8. If target switching requires confirmation, draft finalization blocks in an approval state until a human confirms or rejects it.
9. Once final, Cybros materializes immutable `ConversationRun` and snapshots the final run inputs.
10. The programmable agent is invoked through the selected agent deployment.
11. LLM calls must pass the selected provider credential limiter.
12. Dangerous or external actions are sent to Nexus against the selected execution target and must pass the resolved execution quota.
13. The run finishes with a durable run snapshot, transcript output, and audit trail.

The run snapshot should record:

- agent deployment and deployment fingerprint
- execution target
- selected provider credential
- effective `agent_config`
- resolved runtime governor facts

## Target Selection

### Default Rule

Each conversation has a default execution target.

### Agent Influence

The agent should be able to influence target selection as much as possible, but only through Cybros-managed APIs.

The intended model is:

- agent proposes
- Cybros validates
- policy decides
- confirm policies block and wait for human approval
- `ConversationRun` records the final choice only after the draft is finalized

### History Rule

The same conversation may use different execution targets across runs.

This is safe because each `ConversationRun` snapshots the actual target used.

## Workspace Semantics

- a workspace is always scoped to one execution location
- no automatic sync is assumed between locations
- the same repo on two machines is treated as two workspaces
- user or agent is responsible for choosing the right workspace

## Agent Deployment Failure

If the selected agent deployment is unreachable, unhealthy, or throws a host-level execution error:

- Cybros should raise a specific agent-deployment runtime error
- the current DAG node should fail in a retryable way
- the operator may fix the deployment and retry
- the operator may also switch the conversation to another agent program and retry

Possible future remediation:

- a built-in read-only recovery agent may help diagnose deployment failures

This is a later enhancement, not a v1 dependency.

## Runtime Governance Rules

### Provider Limits

- each configured provider credential has its own limiter
- v1 allows one active credential per `provider_key`
- provider limits are independent from background-job throughput
- provider limits apply to remote LLM API usage

### Job Throughput

- ActiveJob/Solid Queue concurrency should be tunable by operators
- default throughput should be raised above the current conservative baseline
- job throughput is not the only governor in the system
- job throughput is deployment-scoped runtime configuration, not an account preference

### Execution Limits

- code execution is protected by execution quotas
- the base quota is defined on `ExecutionLocation`
- `ExecutionTarget` may override that quota
- `AgentProgram` RPC calls are not separately rate-limited in v1

## Automation Rule

Every automation must bind to an execution target. There is no implicit "run somewhere" behavior.

The automation domain model should land before the automation UI.

Each automation run resolves the currently active deployment at execution time and snapshots the resolved deployment facts.

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
- `conversation_target_propose`

The implementation may use other names, but the boundary should stay this clear.
