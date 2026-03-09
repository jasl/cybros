# Architecture

## Hard Invariants

- Cybros is the control plane and the sole system of record.
- External programmable agents are bounded runtimes, not peer workflow owners.
- The canonical agent loop runs through Cybros for planning, policy, approval, finalization, execution handoff, transcript, and audit.
- `AgentProgram` is the selectable identity. `AgentDeployment` is the connectable binding.
- Nexus is an execution substrate, not a programmable-agent runtime.
- Stable infrastructure such as automation, memory, knowledge, MCP, and future protocol surfaces belongs in Cybros substrate.
- Off-loop agent elasticity is allowed, but anything that mutates Cybros product state or governed execution must come back through Cybros surfaces.

## Runtime Roles

### Cybros

Cybros owns:

- conversations and automations as product entrypoints
- DAG orchestration and run lifecycle
- provider selection and runtime governance
- policy, approval, and permission-preset compilation
- kernel service surfaces for settings, config, KV, target discovery, memory, knowledge, tools, and connectors
- transcript, observability, and audit

### Programmable Agent

A programmable agent is a trusted out-of-process application that supplies:

- planning logic
- persona and workflow logic
- domain-specific orchestration
- agent-owned off-loop capabilities

It does not own:

- canonical run lifecycle
- final prompt assembly
- final tool policy
- direct storage mutation inside Cybros
- direct host execution without Cybros governance

### AgentDeployment

An `AgentDeployment` is the reachable runtime binding Cybros can invoke for one `AgentProgram`.

It owns:

- transport details
- deployment secret binding
- inspection and health facts
- activation state
- deployment fingerprint

It does not replace the program contract as product truth.

### Nexus

Nexus owns:

- shell, file, browser, and desktop execution
- sandbox and execution capacity enforcement for execution work
- execution against selected targets

It does not own:

- conversation state
- programmable-agent lifecycle
- prompt planning
- product policy

## System Shape

```text
User / Automation / Channel Trigger
  -> Cybros entrypoint
  -> RunDraft planning
  -> bounded `agent_rpc` session to AgentDeployment
     -> scoped callbacks into Cybros kernel surfaces
  -> Cybros finalization and execution orchestration
  -> Nexus work against one ExecutionTarget
  -> Cybros transcript, audit, and follow-up state
```

## Canonical Loop Boundary

Agent-owned outputs remain declarative:

- prompt fragments
- workflow decisions
- staged public-surface requests
- execution-target proposals

Kernel-owned authority remains final:

- prompt assembly
- draft commit or discard
- approval park and resume
- deployment pinning
- run materialization
- tool orchestration
- runtime governance
- transcript and audit

## Boundary Rules

- Product code uses public product surfaces, not raw storage internals.
- Conversation and automation defaults affect future drafts only.
- `turn.prepare` is planning-only and cannot durably commit public state.
- Approval resume continues from persisted draft state and does not reopen planning.
- Each run snapshots one finalized contract and execution context instead of mutating history.
- Subagents remain owned by the top-level agent that launched them for that turn.
- Compatibility layers are optional. Correct long-term boundaries take priority over preserving transitional shapes.
