# Kernel Service Surface

## Purpose

Cybros is not only a run planner. It is also the substrate that programmable agents rely on during the canonical loop.

This document defines which services belong to Cybros kernel, which ones are built-in but replaceable, and where off-loop agent elasticity is allowed.

## Boundary Rule

An external agent may have its own memory, connectors, skills, or auxiliary workflows.

That flexibility is acceptable outside the canonical loop.

The hard boundary is narrower:

- if an action changes Cybros product state
- if an action affects governed execution
- if an action must be audited as part of the run

then it must pass through a Cybros-owned surface.

## Kernel-Owned Surfaces

### 1. Conversation And Lane Control Surface

These are the canonical programmable surfaces for conversation-scoped and lane-scoped state:

- `conversation.settings.get`
- `conversation.settings.update`
- `conversation.config.get`
- `conversation.config.update`
- `lane.kv.get`
- `lane.kv.set`
- `lane.kv.delete`
- `lane.kv.list`
- `lane.kv.snapshot`
- `lane.prompt_buffer.put`
- `lane.prompt_buffer.get`
- `lane.prompt_buffer.list`
- `lane.prompt_buffer.delete`
- `lane.prompt_buffer.clear`
- `lane.prompt_buffer.snapshot`
- `lane.prompt_buffer.render`
- `tokens.estimate_text`
- `tokens.estimate_messages`
- `execution_target.list`
- `execution_target.get`

These calls are:

- policy-gated
- scoped to a bounded session
- staged on `RunDraft` when invoked during planning
- audited when they commit

Current shipped nuance:

- `lane.prompt_buffer.render(max_tokens:)` is available to the agent as a token-aware selective read surface
- the bundled/default prompt builder does not yet use that API as its own hot path; it currently reads lane prompt-buffer entries and injects grouped sections directly into prompt assembly
- execution-target switching now cuts over through durable `planning.execution_target_proposal`, not an agent callback mutation
- bootstrap conversation state changes stay kernel-owned through `cybros_*` authority tasks such as `cybros_seed_message`, `cybros_bootstrap_state`, and `cybros_generate_title`

### 2. Memory Surface

Memory is Cybros substrate, not just an agent-local convenience.

V1 direction:

- ship a built-in baseline implementation
- support external memory adapters later or alongside it
- keep scope, visibility, and audit under Cybros control for the canonical surface

Required product properties:

- explicit scope and visibility model
- retrieval-oriented contract
- durable writes with audit
- reusable citation or retrieved-snippet semantics for prompt assembly and user-facing references

### 3. Knowledge Surface

Knowledge is distinct from memory.

Knowledge covers imported, curated, or indexed sources such as:

- uploaded documents
- repository documentation
- external corpora

V1 direction:

- keep a built-in baseline
- allow external retrieval providers
- require provenance and citation-friendly results on the canonical surface

Static prompt injections are one implementation strategy, not the whole knowledge model.

### 4. Tools, MCP, And Skills

Tools remain a Cybros-owned runtime surface because tool policy, approvals, execution routing, and audit are part of the kernel.

Stable responsibilities that belong in Cybros:

- tool registry
- tool policy compilation
- repair and retry loops
- MCP transport and spec-aligned integration
- execution routing into Nexus or other approved adapters

Skills may remain a thinner surface than tools, but when they participate in the canonical loop their discovery, visibility, and policy behavior should still be expressible through Cybros.

### 5. Connectors And Future Stable Protocol Surfaces

Some infrastructure belongs in Cybros because the demand is stable across product categories.

That set includes:

- MCP and other connector protocols
- automation
- channel or surface adapters
- future A2UI surfaces
- future Agent2Agent surfaces

These may be implemented incrementally, but their architectural home is Cybros substrate rather than per-agent application code.

### 6. Observability And Audit

Runs, approvals, retries, capacity waits, target changes, and deployment failures are Cybros facts.

Agents may emit their own telemetry, but product-grade audit belongs to Cybros.

## Built-In Versus Replaceable

The intended V1 split is:

- built-in and core: run orchestration, policy, approvals, tool loop, MCP transport, execution routing, audit
- built-in baseline with adapters: memory and knowledge
- agent-extensible: domain logic, vertical workflows, off-loop services, agent-private retrieval systems

This lets Cybros provide a strong common substrate without forcing every domain-specific behavior into the kernel.
