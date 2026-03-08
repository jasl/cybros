# Architecture

## Runtime Roles

### Cybros

Cybros is the control plane and runtime kernel. It owns:

- conversations and DAG orchestration
- LLM calls and tool loop orchestration
- provider-credential rate limiting
- job concurrency governance
- policy and approval
- memory and knowledge services
- scheduling and automation
- UI and surface adapters
- observability and audit

### Agent Program

An agent program is a standalone application that contains programmable agent logic.

It is responsible for:

- prompt assembly logic
- persona and workflow logic
- hooks
- calling Cybros RPCs
- managing its own internal conventions and namespaces

It is not responsible for:

- the core LLM loop
- the core tool loop
- direct execution against locations
- direct mutation of Cybros storage internals

### Agent Deployment

An agent deployment is the registered, connectable binding Cybros uses to reach a programmable agent.

It owns:

- transport binding
- endpoint or local invocation details
- auth or secret reference
- healthcheck and inspection snapshots
- manifest and schema discovery snapshots
- activation state

### Nexus

Nexus is the execution substrate.

It owns:

- command execution
- file operations
- browser and desktop automation
- deployment and data-collection jobs
- execution workspace access
- execution quota enforcement
- sandbox profile enforcement

It does not host programmable agents.

## System Shape

```text
User / Automation / Channel
  -> Cybros Conversation API
  -> Cybros Run Planning / Draft Finalization
  -> AgentDeployment `agent_rpc` session to programmable agent
  -> Cybros LLM / Tool orchestration
  -> Nexus directive execution against an execution target
  -> Cybros events / transcript / audit
```

## Turn Control Boundary

Programmable agents return high-level intent, not direct runtime mutations.

Agent-owned outputs include:

- prompt fragments and workflow decisions
- hook results
- staged public API requests for settings, agent config, and KV
- execution-target proposals

Kernel-owned final authority includes:

- final prompt assembly
- draft mutation commit or discard
- DAG node and edge mutation
- tool-loop orchestration
- tool-policy merge
- deployment pinning and session authorization
- approval and retry/resume
- durable run snapshots and audit

The kernel may merge, defer, reject, or require approval for agent intent when policy or runtime invariants require it.

## Boundary Rules

- Product code uses `Conversation` public APIs, not raw DAG internals.
- Agent control is high-level and policy-gated.
- `turn.prepare` is planning-only; draft-time public mutations are not durably committed until finalization.
- Execution routing is explicit and auditable.
- A finalized run pins one deployment binding for execution instead of silently drifting to a new active deployment.
- Provider limits, job concurrency, and execution quotas are separate governors.
- The system snapshots run-time decisions per run instead of mutating history.
- Compatibility layers are optional, not required.
