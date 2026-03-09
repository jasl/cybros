# Programmable Agent Architecture Review Findings

## Status

Final evidence log for the architecture review.

`2026-03-09-programmable-agent-architecture-review.md` is the normative conclusion document.

This file keeps the supporting findings, codebase mismatches, and evidence pointers that informed that conclusion.

## Initial Working Conclusions

### 1. The target architecture is directionally correct

The current product and plan set already converges on the right high-level shape:

- Cybros as control plane and system of record
- bounded external programmable agents
- `RunDraft` for planning
- immutable `ConversationRun` for execution audit
- `AgentDeployment` as the connectable runtime unit
- explicit execution targets and split runtime governance

This is a strong baseline and does not look like a dead end.

### 2. Stable substrate capabilities are still under-documented at the product layer

Several capabilities that the product clearly treats as first-class infrastructure are not yet carried by equally stable product docs:

- automation is present, but its semantics are spread across `domain_model.md`, `execution_model.md`, roadmap, and plans
- memory and knowledge are acknowledged in product docs, but their actual architecture mostly lives in `docs/agent_core/`
- connectors and MCP are treated as important infrastructure, but the product contract is still partly implicit

This creates avoidable drift pressure between product docs, plans, and implementation docs.

### 3. The current implementation still reflects Phase 0 assumptions in several critical places

The current runtime resolver and memory wiring still contain pre-rebaseline assumptions:

- conversation runtime selection still reads from metadata-driven agent state in `lib/cybros/agent_runtime_resolver.rb`
- workspace selection still falls back to `Rails.root` or `Dir.pwd`
- the default memory store is global (`conversation_id: nil`) and therefore does not yet match the intended state taxonomy for conversation-scoped memory versus other scopes
- memory and skills can be auto-allowed as a Phase 0 convenience in the resolver

These are expected transitional mismatches, but they should be treated as deliberate rewrite targets, not small implementation details.

## Provisional Findings By Review Task

### Platform Sovereignty

Working view:

- likely `partially_satisfied`

Early evidence:

- product docs consistently position Cybros as the control plane
- the public API boundary is explicit in product and AgentCore docs
- implementation still exposes metadata-driven profile selection and default workspace inference that belong to the old system shape

### Interactive Conversation Path

Working view:

- likely `mostly_satisfied`

Early evidence:

- `execution_model.md` defines a coherent draft -> approval -> finalization -> execution path
- conversation defaults and run snapshots are separated in product docs
- some conversation-facing infrastructure still depends on old runtime resolver assumptions

### Automation Path

Working view:

- likely `partially_satisfied`

Early evidence:

- automation is clearly intended to be a first-class aggregate
- product semantics are spread across multiple documents instead of anchored in one stable spec

### Operator And Deployment Lifecycle

Working view:

- likely `mostly_satisfied`

Early evidence:

- program versus deployment responsibilities are well separated in the product model
- the operator lifecycle looks present in design docs, but needs a stricter product-level contract and plan ownership review

### Runtime Correctness

Working view:

- likely `mostly_satisfied`

Early evidence:

- the plans now sharply distinguish draft and run semantics
- runtime governance separation is sound
- correctness depends on plan sequencing staying coherent across the two active implementation plans

### Long-Term Evolution

Working view:

- likely `partially_satisfied`

Early evidence:

- the substrate seems capable of expressing multiple agent product forms
- some long-term infrastructure classes still need cleaner product-level anchoring, especially automation, memory/knowledge, and connectors/protocol surfaces

## Reference Product Capability Notes

Early cross-product mapping suggests the current rebaseline can already express:

- coding-agent products such as Codex and OpenCode
- hook-first or programmable CLI agents such as Bub
- large parts of research, desktop, and trading agents such as Accomplish and OpenAlice

The substrate gaps that still look materially important for faithful product expression are:

- multi-surface and channel-routing contracts
- plugin or skills trust and signing model
- stronger sandbox and runtime-capability contracts for execution safety
- a first-class lorebook or triggered knowledge-injection layer for roleplay-grade products

These do not invalidate the rebaseline, but they should shape the document revision blueprint and future roadmap framing.

## Candidate High-Severity Issues

### A. Product docs still rely on plans for some stable substrate semantics

The product docs are supposed to be normative, but key semantics are still easiest to recover from plans or AgentCore docs:

- automation is first-class but not anchored in its own stable product contract
- memory and knowledge have product significance but their architecture mostly lives under `docs/agent_core/`
- connectors and protocol-surface infrastructure remain implied rather than explicitly modeled at the product layer

### B. Product contract should distinguish canonical-loop authority from off-loop agent elasticity

Current product docs correctly deny agent ownership of the canonical loop, but they still read as if all meaningful tool-loop or capability behavior must live inside Cybros.

The intended boundary is narrower and more precise:

- canonical loop authority stays in Cybros
- agent-owned capabilities may exist outside that loop
- anything that affects Cybros product state or governed execution must re-enter through Cybros

This distinction should be written directly into the product docs.

### C. Implementation plans have drifted relative to the current document baseline

At least one active implementation plan still describes product-doc work as if it does not already exist.

Example:

- `docs/plans/2026-03-08-runtime-governance.md` Task 1 says to create `docs/product/runtime_governance.md`, but that product doc already exists in the current tree

This suggests the executable plans need pruning and resequencing before they are used as the implementation source of truth.

### D. Current implementation still hardcodes old runtime assumptions

The runtime resolver still depends on metadata-driven selection and globalized defaults that conflict with the rebaseline:

- metadata-driven agent profile and model selection
- workspace defaults from `Rails.root` / `Dir.pwd`
- Phase 0 auto-allow for memory and skills tools
- global memory store default instead of explicit scoped memory substrate

### E. Active implementation plans have real authority and sequencing conflicts

The review of the active plans surfaced several concrete issues:

- target-switch semantics are split across discovery rules, permission presets, execution model text, and executable tests instead of one canonical resolver contract
- ownership of `ExecutionLocation`, `Workspace`, and `ExecutionTarget` creation is still ambiguous at the executable-plan level
- permission presets assume stable tool `permission_class` metadata, but no executable task clearly owns that rollout
- draft planning currently lands ahead of the deployment lifecycle work it depends on
- automation is treated as active product semantics, but the executable work mostly covers schema and defaults rather than runtime behavior
- the initial programmable-agent fixture harness is under-scoped relative to later RPC, callback, approval, and drift scenarios

These are not just style issues. They are likely sources of implementation churn unless the plans are rewritten before execution.

### F. Product docs still lack a clean contract surface for bounded external runtimes

The product-doc review surfaced several structural problems:

- there is no immutable contract or version artifact cleanly separating `AgentProgram` from a live `AgentDeployment`
- the documented programmable surface does not yet match Cybros's claimed kernel ownership for memory, knowledge, MCP, skills, and related services
- runtime governance does not yet say how bounded external agent runtime capacity is handled or intentionally deferred
- some docs still conflict on whether the product selects `AgentProgram` or `AgentDeployment`
- the run lifecycle is split across multiple documents without one canonical end-to-end sequence
- global agent config exists in the vocabulary but not in the first-class runtime model

These point toward a documentation-structure rewrite, not just wording cleanup.

### G. AgentCore boundaries are stronger than Cybros product docs, but Cybros wiring still lags behind

The implementation review suggests:

- `AgentCore` itself already has the right shape for long-term engine boundaries
- tools and MCP are the most mature and should remain core engine capabilities
- skills are reasonably adapter-shaped, but their metadata remains advisory rather than policy-authoritative
- memory is interface-shaped but not yet product-shaped; the default store and contracts lag behind the documented scope and citation model
- knowledge is still mostly a design-doc concept rather than a first-class runtime contract
- the default Cybros runtime resolver still hardcodes Phase 0 composition and does not wire prompt-side memory and skills capabilities the way the docs imply

This means the architecture review should not treat AgentCore as the main problem. The bigger problem is that Cybros product docs and default resolver wiring have not caught up to the engine direction.

## Evidence Pointers

### Product Docs

- `docs/product/architecture.md`
- `docs/product/domain_model.md`
- `docs/product/execution_model.md`
- `docs/product/programmable_agents.md`
- `docs/product/state_taxonomy.md`
- `docs/product/runtime_governance.md`

### Plans

- `docs/plans/2026-03-09-programmable-agent-preflight-design.md`
- `docs/plans/2026-03-08-phase-1-schema-cut-list.md`
- `docs/plans/2026-03-09-agent-deployment-connection-design.md`
- `docs/plans/2026-03-08-runtime-governance-design.md`

### Current Implementation Mismatches Worth Rechecking

- `lib/cybros/agent_runtime_resolver.rb`
- `lib/agent_core/resources/memory/base.rb`
- `lib/agent_core/resources/memory/pgvector_store.rb`
- `docs/agent_core/public_api.md`
- `docs/agent_core/knowledge_context_memory_design.md`
