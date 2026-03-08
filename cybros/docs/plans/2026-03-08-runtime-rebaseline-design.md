# Runtime Rebaseline Design

> **Update 2026-03-09:** Deployment registration, transport, and run materialization assumptions in this document are superseded by `docs/plans/2026-03-09-agent-deployment-connection-design.md`.

## Goal

Reframe Cybros around the correct long-term architecture:

- Cybros as runtime kernel and control plane
- programmable agents as trusted out-of-process applications
- Nexus as execution substrate only
- execution target as a first-class product concept

## Core Decisions

### 1. Destructive Refactor Is Explicitly Allowed

The project is still early. Existing product models, roadmap phases, and even DAG integration details may change if they block the correct architecture.

### 2. Programmable Agents Are Not Profiles

The old `agent_profile`-driven conversation model is not the target architecture.

V1 programmable agents are:

- self-hosted
- trusted
- out-of-process
- lifecycle-managed through setup, install, and healthcheck

The runnable unit is not just an agent program. It is a connectable `AgentDeployment`.

### 3. Nexus Is Not The Agent Runtime

Nexus remains the managed execution layer for shell, files, browser, desktop, deploy, and other dangerous execution surfaces.

### 4. Execution Target Is `Location + Workspace`

The system must model where execution happens explicitly.

- conversation has a default execution target
- a run snapshots the actual target used
- the agent may propose target changes
- no workspace sync is assumed across locations

`ExecutionLocation`, `Workspace`, and `ExecutionTarget` are canonical Cybros product models.

Conduits must adapt to them.

### 5. Conversations Are Programmable Through Public APIs

The agent should have broad control over the conversation's public surface.

That includes:

- public settings
- shared per-conversation KV
- target proposals

It does not include direct mutation of DAG internals or system bookkeeping fields.

### 6. Target Switch Confirmation Blocks

If an agent proposes switching execution targets and the resolved policy requires confirmation, the run must block and wait for human approval.

### 7. Agent Deployment Failures Are Retryable

If an agent deployment is unavailable or unhealthy at invocation time, Cybros should surface a specific runtime error and the affected DAG node should remain retryable.

### 8. Automation Infrastructure Lands Before Automation UI

Automation should bind to the same agent and execution-target primitives as interactive runs.

## Resulting Product Layers

### Runtime Kernel

Owned by Cybros:

- conversation model
- DAG orchestration
- LLM/tool loop
- policy and approval
- memory and knowledge
- automation
- observability

### Programmable Agent Runtime

New layer:

- deployment registration
- inspection and healthcheck
- manifest and config schema discovery
- agent request handling

### Execution Layer

Owned canonically by Cybros at the product-model layer, with Nexus as the execution substrate:

- execution locations
- workspaces
- execution targets
- directives
- sandbox policies

## Immediate Consequence For Planning

The old roadmap should no longer drive implementation order.

The new order should be:

1. freeze and archive the old product docs
2. define the new product domain
3. implement first-class agent and execution-target models
4. re-align Nexus protocol semantics
5. rebuild product surfaces on top of the new model
