# Vision

## Positioning

Cybros is an agent runtime kernel and control plane.

It should provide the core services agents need:

- human interfaces
- conversation orchestration
- LLM orchestration
- tool execution routing
- execution environment management
- memory and knowledge services
- scheduling and automation
- agent registration and lifecycle
- observability and audit

Cybros itself is not the app-specific intelligence. It is the operating system layer. Programmable agents are the apps.

## Product Principles

- `Architecture first`: destructive refactors are allowed early to keep the system clean.
- `Public API over storage access`: product features talk to `Conversation` and other public facades, not raw DAG internals or ad hoc metadata writes.
- `Trusted self-hosted agents first`: v1 assumes the operator is responsible for the safety of agent code they deploy.
- `Dangerous execution is separate`: shell, file mutation, browser, desktop, and deployment actions run through managed execution targets, not inside the agent deployment environment itself.
- `Execution target is explicit`: every run must know which `location + workspace` it used.
- `No cross-location sync in v1`: the same repo on two machines is treated as two workspaces.
- `Agent has high conversation control`: the agent may request public conversation setting and KV changes through policy-gated APIs, but draft-time changes stay staged until Cybros finalizes the run plan.

## Non-Goals For V1

- third-party marketplace
- plugin system design
- cross-location workspace replication
- per-agent strong isolation by default
- treating Nexus as the programmable-agent runtime

## V1 Trust Model

- agent programs are trusted and self-hosted
- agent deployments are out-of-process
- dangerous execution stays in Nexus-managed targets
- policy, session scoping, and audit remain the system boundary for user-visible control
