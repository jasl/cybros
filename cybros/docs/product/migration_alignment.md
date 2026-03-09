# Migration Alignment

This document maps the current codebase to the programmable-agent target architecture.

It is intentionally blunt. Transitional compatibility is not the goal.

## Immediate Mismatches

### 1. Conversation Runtime Selection Is Still Metadata-Shaped

Current state:

- conversations still rely on metadata-driven agent/runtime defaults
- there is no clean first-class `agent_program` selection path yet
- there is no clean first-class execution-target path yet

Target:

- `Conversation.agent_program_id`
- `Conversation.default_execution_target_id`
- `Conversation.permission_mode`
- metadata is no longer the primary runtime-selection surface

### 2. `ConversationRun` Is Still Too Thin

Current state:

- run records mostly track lifecycle and DAG linkage
- they do not snapshot the full execution context

Target:

- immutable run snapshots record program, contract, deployment, target, provider, settings, config, and governor facts

### 3. `AgentProgram` Still Looks Like A Local Runtime Wrapper

Current state:

- it still reflects local-path and runtime-surface assumptions
- it does not yet cleanly own published contract identity and global config

Target:

- `AgentProgram` becomes the selectable identity and contract owner
- `AgentDeployment` owns connectivity and health

### 4. `AgentDeployment` Does Not Exist As A First-Class Runtime Binding

Current state:

- registration, inspection, activation, and health are not yet modeled as product concepts

Target:

- introduce `AgentDeployment` as the only connectable runtime unit

### 5. Draft And Run Semantics Are Still Mixed

Current state:

- planning and execution concerns still leak into the same runtime shapes

Target:

- `RunDraft` is durable mutable planning state
- `ConversationRun` is immutable execution state

### 6. Execution Context Still Falls Back To Process Defaults

Current state:

- the runtime resolver still falls back to `Rails.root` or `Dir.pwd`

Target:

- execution context resolves through explicit `ExecutionTarget`

### 7. Memory, Knowledge, MCP, Tools, And Skills Are Stronger In Engine Docs Than In Product Docs

Current state:

- `AgentCore` has meaningful boundaries
- product docs still under-specify memory, knowledge, and connector surfaces
- default resolver wiring still reflects Phase 0 assumptions

Target:

- product docs explicitly define kernel service surfaces
- built-in versus adapter boundaries are intentional
- runtime wiring matches the stated contract

### 8. Automation Is Still Under-Owned

Current state:

- automation semantics are spread across docs and plans
- the runtime path is not yet treated as a first-class implementation track

Target:

- automation becomes an explicit aggregate, lifecycle, and implementation plan

### 9. Runtime Governance Is Still Partly Implicit

Current state:

- provider limits, job settings, and execution quotas are not yet modeled as one coherent runtime system

Target:

- explicit provider credential governance
- explicit runtime settings
- location-first execution quotas with target override
- durable waits and admission recovery

### 10. Plan Sequencing Still Encourages Rework

Current state:

- some plans still put draft planning ahead of deployment lifecycle
- target-switch authority is spread across multiple documents
- automation runtime behavior is under-owned

Target:

- deployment lifecycle lands before planning depends on it
- one canonical target-switch contract
- automation gets its own implementation track

## Recommended Implementation Sequence

Use `docs/plans/README.md` as the task-level execution order. At repository level, the preferred cutover sequence is:

1. Freeze the product contract and rewrite plans to match it.
2. Land first-class schema for programs, deployments, drafts, executions, and automation.
3. Land runtime-governance schema and admission primitives.
4. Land deployment registration, inspection, and activation.
5. Land conversation agent, permission, and target defaults plus the public kernel surfaces.
6. Land draft planning, finalization, approval resume, and replay-safe RPC.
7. Land automation dispatch on the same canonical lifecycle.
8. Rebaseline the runtime resolver onto explicit targets and contract snapshots.
9. Re-align Nexus and Conduits to the execution-only role.
10. Finish product surfaces and end-to-end coverage after the domain model is stable.

## Destructive Refactor Rule

When old implementation shapes conflict with the target model:

- prefer deletion over adapters
- prefer schema rewrite over transitional compatibility columns
- prefer smaller explicit APIs over preserving ambiguous convenience layers
