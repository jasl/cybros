# Programmable Agent Architecture Review Design

## Goal

Perform one final architecture review of the programmable-agent rebaseline before implementation starts, then turn the review into concrete product-doc and plan-doc revisions.

The review must answer one primary question:

Can Cybros support programmable agents as an external agent runtime platform without another architectural reset?

## Product Target

This review uses the following target architecture as the evaluation baseline:

- Cybros is the control plane and the sole system of record.
- External programmable agents are first-class but bounded runtimes.
- The canonical agent loop must execute through Cybros.
- Stable infrastructure belongs in Cybros:
  - deployment registration and health
  - execution target routing and governance
  - permissions, policy, and approvals
  - automation
  - connectors and spec-aligned protocol surfaces such as MCP
  - built-in but replaceable memory and knowledge substrate
- Domain-specific vertical logic belongs primarily to external agent programs unless it is clearly shared infrastructure.

## Review Scope

The review covers four material layers:

1. Product documents under `docs/product/`
2. Active design and implementation plans under `docs/plans/`
3. Current implementation and technical docs for memory, knowledge, MCP, tools, and skills
4. Reference products under `references/` as capability benchmarks rather than design templates

## Review Tasks

### 1. Platform Sovereignty

Confirm that Cybros retains orchestration ownership for:

- run planning
- policy and approval
- target selection and validation
- run finalization
- execution handoff
- transcript and audit
- automation dispatch

Allow elasticity outside the canonical loop for agent-owned memory, connectors, tools, or skills so long as Cybros remains the governing loop for product state and governed execution.

### 2. Interactive Conversation Path

Validate the end-to-end path from conversation defaults through planning, approval, execution, and durable transcript output.

### 3. Automation Path

Validate that automation is a first-class execution entrypoint with its own lifecycle semantics, not just a conversation add-on.

### 4. Operator And Deployment Lifecycle

Validate that the platform supports explicit deployment registration, inspection, activation, health, staleness, and replacement without collapsing program and deployment responsibilities.

### 5. Runtime Correctness

Validate that `RunDraft`, `ConversationRun`, RPC sessions, invocation bookkeeping, approvals, quotas, and backoff semantics remain coherent under concurrency and failure.

### 6. Long-Term Evolution

Validate that the substrate can express multiple agent product categories:

- general assistant
- coding agent
- research agent
- trading agent
- chat or roleplay agent

## Cross-Cutting Audit Lenses

Every review task is evaluated through these lenses:

1. Orthogonality of modules, features, and flows
2. Unidirectional dependencies and business data flow
3. Terminology and concept consistency
4. Capability completeness relative to product goals
5. Implementation-plan completeness and sequencing

## Expected Outputs

The final review should produce:

1. A comprehensive architecture review with findings and severity ordering
2. A product capability coverage matrix against the reference agent product set
3. A document revision blueprint for `docs/product/`
4. A document revision blueprint for `docs/plans/`
5. A destructive-allowed architecture correction list where the current baseline should be changed
6. A revised implementation sequencing proposal for the active programmable-agent plans

## Non-Goals

- preserving backward compatibility with superseded plans or schema shapes
- matching the UI or packaging of the reference products
- forcing all agent-owned capabilities into Cybros itself

## Working Rule

When a design is locally consistent but misaligned with the target architecture, the target architecture wins.
