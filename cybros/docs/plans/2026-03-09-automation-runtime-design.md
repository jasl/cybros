# Automation Runtime Design

## Goal

Define automation as a first-class programmable-agent entrypoint instead of a thin wrapper around conversations.

## Core Decisions

### 1. Automation Is Its Own Aggregate

`Automation` owns:

- agent program selection
- execution target selection
- permission preset
- schedule or trigger definition
- optional conversation binding

It does not collapse into `Conversation`.

### 2. Automation Uses The Canonical Run Lifecycle

Automation dispatch opens a `RunDraft`, resolves deployment and governors, and materializes immutable run records the same way interactive execution does.

There is no special automation-only execution path that bypasses drafts or snapshots.

### 3. Deployment Resolves At Execution Time

Automation binds to `AgentProgram`, not directly to a deployment id.

Each automation run resolves the currently active healthy deployment and snapshots the result.

### 4. Default Permission Mode Is `full_access`

Automation is non-interactive by default.

Its default preset is therefore `full_access`.

### 5. Manual Approval Is Explicit, Not Hidden

If an automation uses a stricter preset and policy returns `confirm`, Cybros must park the automation run in a durable manual-approval state.

It must not silently auto-allow or silently downgrade behavior.

### 6. Automation Runs Are Distinct From Conversation Runs

`AutomationRun` is its own immutable runtime record.

It may link to a `ConversationRun`, but it does not collapse into one.

### 7. Conversation Binding Is Optional

If an automation binds to a conversation:

- transcript continuity may flow into that conversation
- conversation-scoped settings may participate in the run context

The automation still remains its own product identity.

### 8. Operator Surfaces Land Before Rich End-User Automation UI

V1 must provide operator-visible automation and automation-run state even if a richer end-user automation builder comes later.
