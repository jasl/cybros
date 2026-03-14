# Bundled Agent Rails Host Design

## Status

Approved design notes for replacing the current bundled default agent implementation with a Rails/Puma-hosted `claw` implementation while keeping `agent_rpc.v1` language-neutral and transport-neutral.

## Problem

The current bundled agent under `cybros/agents/default` already behaves like a small web service, but it is hosted by a minimal WEBrick server and mixes "current production baseline" with "future implementation target".

At the same time, a new API-only Rails skeleton already exists under `cybros/vendor/agents/claw`.

The cleaner migration is not:

- move `claw` into `agents/default`
- finish the host migration
- then rename everything again

That path creates unnecessary churn and makes it harder to prove whether behavior drift came from:

- host migration
- source-tree moves
- runtime-identity rename

The better path is:

- keep `cybros/agents/default` intact as the known-good baseline
- merge its effective logic into `cybros/vendor/agents/claw`
- prove `claw` and `default` are behaviorally aligned
- then switch the bundled implementation to `claw`
- finally remove the old `default` tree

## Goals

- keep `agent_rpc.v1` as the canonical Cybros-to-agent protocol
- preserve HTTP JSON-RPC transport shape and callback-session semantics
- preserve recognized-deployment binding and runtime drift behavior
- use Rails/Puma for the new bundled implementation host
- keep the current `default` implementation intact until `claw` reaches parity
- validate `claw` against `default` side-by-side before product cutover
- cut over the bundled runtime identity and canonical source root to `claw`
- delete the old `default` implementation after cutover succeeds
- take advantage of Rails on the agent side to add stronger unit, request, and integration tests

## Non-Goals

- no WebSocket-first transport
- no ActionCable requirement on the Cybros-to-agent hot path
- no change to Cybros product/runtime boundaries
- no requirement that external agents use Ruby or Rails
- no requirement that Active Record or Active Job participate in the request hot path
- no protocol expansion justified only by the new host framework

## Core Decision

Adopt a side-by-side migration:

1. freeze and retain `cybros/agents/default` as the baseline bundled implementation
2. merge its effective runtime logic into `cybros/vendor/agents/claw`
3. prove parity between the two implementations
4. promote `claw` into the canonical bundled source root
5. switch bundled identity from `default` to `claw`
6. remove the legacy `default` tree

Rails is the host implementation.
It is not the protocol.

## Source Layout

### Temporary Migration Layout

- baseline bundled implementation: `cybros/agents/default`
- migration workspace: `cybros/vendor/agents/claw`

### Final Layout

- canonical bundled implementation: `cybros/agents/claw`

The `vendor/agents/claw` tree should not survive the cutover.

## Transport And Process Model

### Canonical Transport

The Cybros-to-agent transport remains synchronous HTTP JSON-RPC.

Why:

- Cybros already models invocation lifecycle, callback-session authorization, replay, and drift detection around request/response RPC
- current hook calls are discrete lifecycle invocations, not a natural duplex stream
- switching transport while changing host implementation would enlarge the migration without solving the main operational issue

The intended runtime shape remains:

- `POST /rpc` as canonical JSON-RPC entrypoint
- `GET /health` as health and identity inspection endpoint
- `transport_kind = http_jsonrpc`

### Process Model

The new `claw` implementation should behave as a stateless concurrent HTTP service from Cybros's perspective.

Each hook call is handled as an independent request.
Puma provides concurrency.
Any Cybros callback usage still happens through explicit outbound HTTP requests using the provided callback session.

There is no connection affinity requirement in V1.

## Component Boundaries

The new implementation should follow a "Rails shell + pure Ruby agent core" split.

### Rails Shell Responsibilities

- request routing
- bearer authentication at the HTTP boundary
- JSON parsing and response rendering
- error-to-status / error-to-JSON-RPC mapping
- configuration loading
- structured logging
- Puma process management

### Agent Core Responsibilities

- manifest loading
- identity construction
- prompt loading and assembly
- RPC method dispatch
- hook implementations
- attachment import translation
- callback client behavior

### Boundary Rule

Controllers stay thin.
They should not contain bundled-agent business logic.

Instead:

- controller -> runtime -> dispatcher -> pure Ruby hook/service object

This keeps the agent logic testable without requiring a live Rails request object or local database state.

## Optional Rails Subsystems

`ActiveRecord` and `ActiveJob` may remain available in `claw`, but they are optional implementation capabilities, not protocol requirements.

Hard rule:

- `initialize`, `agent.health`, lifecycle hooks, and callback usage must not require local database state or background-job completion to be correct

Because `claw` is Rails-based, we should use that framework advantage to strengthen testing:

- unit tests for runtime objects
- request tests for `/rpc` and `/health`
- integration tests for full host behavior

## Parity Strategy

Behavioral parity is a first-class migration requirement.

Before product cutover, we should be able to run both implementations side-by-side and verify that they agree on the externally observable contract for:

- `initialize`
- `agent.describe`
- `agent.health`
- `agent.schemas.get`
- `capabilities.handshake`
- `capabilities.refresh`
- `attachments.import`
- `on_conversation_created`
- `on_lane_first_user_message`
- `before_agent_step`
- `on_context_pressure`
- `before_subagent_spawn`
- `before_finalize_output`
- `after_task_notice`
- `after_subagent_result`

Parity means:

- same method surface
- same identity and manifest semantics, except for the deliberate final rename to `claw`
- same hook/result structure
- same attachment import shape
- same error semantics at the protocol boundary

## Identity Cutover

Only after parity is proven should the bundled identity switch from `default` to `claw`.

That cut includes:

- canonical bundled source root changes from `cybros/agents/default` to `cybros/agents/claw`
- `bundled_agent_key` changes from `default` to `claw`
- manifest identity fields become `claw`-based
- bootstrap constants, deployment fingerprints, bearer references, and user-facing naming change accordingly
- product/runtime special-casing that hard-codes `"default"` must be updated

This identity cut is intentionally separate from the parity phase because it will cause deliberate churn in:

- bundled source resolution
- bootstrap fixtures
- recognized deployment identity strings
- tests that hard-code `default`

## Cutover Strategy

Cut over in five phases:

1. freeze the current `default` contract with tests
2. complete the `claw` Rails host in `cybros/vendor/agents/claw`
3. merge `default` runtime logic into `claw` and prove side-by-side parity
4. move `claw` to `cybros/agents/claw` and switch bundled identity/bootstrap to `claw`
5. delete `cybros/agents/default` and any temporary `vendor/agents/claw` residue

During phases 1-3:

- `cybros/agents/default` remains the shipped baseline
- no product bootstrap should point at `claw` yet
- identity strings should remain stable unless a parity test explicitly needs dual expectations

During phases 4-5:

- `claw` becomes the bundled implementation
- `default` becomes legacy code scheduled for deletion

## Summary

The approved direction is:

- build the new implementation in `cybros/vendor/agents/claw`
- merge in the effective logic from `cybros/agents/default`
- prove parity while both implementations coexist
- then cut over directly to `cybros/agents/claw`
- keep `agent_rpc.v1` and `http_jsonrpc` unchanged
- use Rails as an implementation advantage, especially for testing
- delete the old `default` implementation once `claw` is the new bundled runtime
