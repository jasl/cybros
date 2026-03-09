# Programmable Agent Architecture Review

## Overall Judgment

The rebaseline is directionally correct and can serve as the V1 architecture baseline after the document rewrite in this review.

Before the rewrite, the architecture had four blocking issues:

- stable product contract lived partly in plans and partly in engine docs
- `AgentProgram` versus `AgentDeployment` selection semantics were still drifting
- automation was first-class in product intent but not first-class in implementation planning
- active plans still reflected Phase 0 or pre-rewrite assumptions in sequencing and ownership

Those issues are document and sequencing problems, not evidence that the target architecture is wrong.

## Baseline Decision

Adopt this baseline:

- Cybros is the sole system of record and control plane
- external programmable agents are bounded runtimes
- the canonical loop always runs through Cybros
- `AgentProgram` is the selectable identity
- `AgentDeployment` is the reachable binding
- stable substrate belongs in Cybros
- vertical domain logic belongs mostly in external agents

## Capability Coverage

| Product Shape | Baseline Result | Notes |
| --- | --- | --- |
| General assistant | Covered by substrate | conversation state, planning, tools, memory, automation, audit |
| Coding agent | Covered by substrate | explicit execution targets and operator-managed environments are strong fits |
| Research agent | Mostly covered | knowledge, memory, scheduling, and citations need stronger runtime wiring than current defaults |
| Trading agent | Mostly covered | automation and guarded execution fit well, but policy and runtime safety need disciplined implementation |
| Chat / roleplay agent | Partially covered | common substrate fits, but lorebook-style knowledge injection remains a future refinement |

## Review Conclusions By Task

### 1. Platform Sovereignty

Result: satisfied after clarification

Why:

- product docs now say Cybros owns the canonical loop and product state
- off-loop agent elasticity is allowed without confusing it for product authority
- kernel service surfaces are now documented as Cybros substrate

Remaining implementation risk:

- current resolver and runtime defaults still reflect Phase 0 assumptions and must be rewritten to match the new contract

### 2. Interactive Conversation Path

Result: satisfied

Why:

- conversation defaults, draft planning, approval park, finalization, and immutable run snapshots now have one canonical lifecycle
- program selection, permission presets, and target selection converge on first-class conversation fields

Remaining implementation risk:

- current `ConversationRun` and conversation controllers are still too thin to match the documented model

### 3. Automation Path

Result: satisfied after plan expansion

Why:

- automation is now documented as a first-class aggregate and a dedicated implementation track
- automation dispatch explicitly reuses the canonical run lifecycle

Remaining implementation risk:

- current codebase still lacks the runtime path and operator surfaces described in the new plan

### 4. Operator And Deployment Lifecycle

Result: satisfied

Why:

- deployment lifecycle is explicit
- deployment inspection facts are separated from program contract truth
- deployment lifecycle now lands before draft planning depends on it

Remaining implementation risk:

- current code still lacks the first-class `AgentDeployment` model and operator surfaces

### 5. Runtime Correctness

Result: mostly satisfied

Why:

- `RunDraft` versus immutable run separation is now explicit
- approval resume and replay-safe `agent_rpc` semantics are coherent
- runtime governance stays orthogonal to deployment lifecycle

Remaining implementation risk:

- failure-path coverage still needs to be enforced in code, not only in docs

### 6. Long-Term Evolution

Result: satisfied

Why:

- the substrate is broad enough for general, coding, research, trading, and chat-style agents
- stable infrastructure is now clearly assigned to Cybros
- knowledge and memory are documented as built-in baseline plus adapter-friendly surfaces

Remaining implementation risk:

- plugin trust, richer roleplay knowledge surfaces, and future Agent2Agent remain intentionally deferred

## Five-Lens Audit Matrix

Legend:

- `yes`: coherent and ready
- `partial`: direction is right but still needs implementation discipline

| Review Task | Orthogonality | One-Way Flow | Terminology | Capability Completeness | Plan Completeness |
| --- | --- | --- | --- | --- | --- |
| Platform sovereignty | yes | yes | yes | yes | partial |
| Interactive conversation path | yes | yes | yes | yes | partial |
| Automation path | yes | yes | yes | yes | yes |
| Operator and deployment lifecycle | yes | yes | yes | yes | yes |
| Runtime correctness | yes | yes | yes | partial | partial |
| Long-term evolution | yes | yes | yes | partial | partial |

## Destructive Corrections Adopted

- added dedicated product docs for agent contract, run lifecycle, automation, and kernel service surfaces
- moved `AgentProgram` back to the only user-selectable agent identity
- made off-loop elasticity explicit without giving up Cybros loop authority
- split automation into its own implementation track
- unified target-switch semantics under one decision contract
- moved deployment lifecycle ahead of planning-dependent tasks
- extended the schema cut with contract fingerprints, global config, and automation-aware draft semantics

## Remaining Code Rewrite Targets

These are the highest-risk implementation mismatches left in code:

- `lib/cybros/agent_runtime_resolver.rb` still uses metadata-shaped selection and workspace fallbacks
- default memory wiring is still overly global and not yet aligned with the documented scope model
- prompt-side memory and skills surfaces are not fully wired by default
- `app/models/conversation_run.rb` and `app/models/agent_program.rb` still reflect older runtime assumptions

## Recommended Next Step

Start implementation from the rewritten plan set in this order:

1. runtime-governance schema and execution-domain source models
2. programmable-agent fixture plus deployment lifecycle
3. conversation runtime defaults and target discovery
4. draft finalization and replay-safe RPC
5. automation runtime
6. resolver and engine wiring cleanup
