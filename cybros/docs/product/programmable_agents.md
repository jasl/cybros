# Programmable Agents

## Definition

A programmable agent is a standalone trusted application that Cybros can register, inspect, configure, and invoke.

It is the app layer on top of the Cybros runtime kernel.

## V1 Constraints

- self-hosted only
- trusted by the operator
- out-of-process
- Ruby-first implementation
- language-agnostic protocol

Future Python or Rust implementations should use the same contract.

## What The Agent Owns

- prompt assembly
- persona and workflow selection
- hook logic
- conversation-level control through public APIs
- use of shared per-conversation KV
- optional external integrations if the operator chooses to enable them

## What The Agent Does Not Own

- the core LLM loop
- the core tool loop
- direct storage mutation inside Cybros
- direct execution on a host without going through Cybros and Nexus

## Lifecycle

### Register

`AgentProgram` source is registered with Cybros.

The operator may point Cybros at local code or clone code locally first and then register it.

### Start Deployment

A deployment may be started:

- outside Cybros
- by an operator
- or by another agent through ordinary execution capabilities if it can reach the relevant environment

### Register Deployment

An `AgentDeployment` is explicitly registered in Cybros once the deployment is reachable.

This is the unit that should become selectable for runtime use.

### Inspect

Cybros records:

- manifest
- config schemas
- healthcheck result
- supported features

### Activate

The agent becomes selectable for conversations and automations.

### Upgrade

The source revision may change over time, including through self-evolution patterns outside Cybros.

The resulting runnable unit is the currently active registered deployment for that program.

## Contract Surface

The agent contract should eventually provide:

- manifest
- global config schema
- per-conversation config schema
- setup command or setup entrypoint
- healthcheck command or healthcheck entrypoint
- turn handler or hook endpoints

The transport and method boundary for those capabilities is defined by `agent_rpc`.

## Deployment Model

- the runnable binding is an `AgentDeployment`
- a deployment may run on bare metal, in a container, or in any other Cybros-reachable environment
- the environment that runs the deployment is not a separate canonical product model in v1

V1 recommendation:

- one agent program has one active deployment at a time
- deployment registration is explicit and operator-managed
- multi-deployment routing is deferred

## Conversation Control

The agent should be allowed to control conversation-level state through public APIs.

This includes:

- public settings
- agent per-conversation config
- shared per-conversation KV
- requests to change execution target

This control is declarative and policy-gated.

The agent requests changes through public APIs, and the Cybros kernel remains authoritative for prompt assembly, DAG mutation, approvals, retries, and audit.

This does not include direct writes to system state.

## KV Rules

- default visibility is shared within the conversation even when agent changes
- namespace isolation is by key convention in v1
- `system.*` is reserved and not agent-writable

## Default Template

The product should ship one default programmable-agent implementation and use it as the starter template for new agents.
