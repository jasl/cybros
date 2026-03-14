# Bundled Default Rails Agent Host Design

## Status

Approved design notes for replacing the bundled default agent's WEBrick host with a Rails/Puma host while keeping `agent_rpc.v1` language-neutral and transport-neutral.

## Problem

The current bundled default agent already behaves like a small web service, but its host is a minimal WEBrick server inside `cybros/agents/default/lib/.../rpc_server.rb`.

That creates two issues:

- the host implementation is intentionally lightweight, but it is not the operational shape we want to carry forward for throughput, concurrency, and maintenance
- the current host shape makes the bundled agent feel "special" in implementation even though product/runtime docs already describe agents as normal bounded runtime endpoints

At the same time, Cybros should not accidentally turn "Rails" into the protocol.

The replacement must improve the host implementation without changing the public runtime contract.

## Goals

- replace the bundled default agent's WEBrick host with a Rails/Puma host
- keep `agent_rpc.v1` as the canonical Cybros-to-agent protocol
- preserve the existing JSON-RPC over HTTP transport shape
- preserve current callback-session semantics, recognized-deployment binding, and runtime drift behavior
- keep the bundled implementation Ruby-first and Rails-friendly without making Rails a protocol requirement
- keep agent application logic portable enough to run and test outside a fully booted Rails request stack

## Non-Goals

- no WebSocket-first transport
- no ActionCable requirement on the Cybros-to-agent hot path
- no change to Cybros product/runtime boundaries
- no requirement that external agents use Ruby or Rails
- no requirement that the bundled default agent use Active Record or Active Job on the request hot path
- no protocol expansion justified only by the new host framework

## Core Decision

Adopt a Rails-first host for the bundled default agent, but keep HTTP JSON-RPC as the canonical transport.

The bundled default agent should become an API-only Rails application hosted by Puma and exposed as a normal bounded runtime endpoint:

- `POST /rpc` remains the canonical `agent_rpc.v1` JSON-RPC entrypoint
- `GET /health` remains the health and identity inspection endpoint
- Cybros continues to treat the deployment as `transport_kind = http_jsonrpc`

Rails is the host implementation.
It is not the protocol.

## Directory Decision

The canonical bundled source root should remain:

- `cybros/agents/default`

It should not live under:

- `cybros/vendor/agents/...`

Reasoning:

- `agents/` correctly communicates that the bundled default agent is first-party Cybros product code
- `vendor/` implies imported or third-party code, which is the wrong ownership model for the default bundled agent
- existing product/design docs already describe `agents/` as the bundled-agent source root

`cybros/vendor/agents/claw` is an acceptable incubation source for the migration, but it should not survive as a second canonical bundled agent tree.

Approved migration rule:

- use `cybros/vendor/agents/claw` as the Rails skeleton source
- promote that skeleton into `cybros/agents/default`
- preserve the bundled default agent's runtime identity as `default`
- delete the temporary `cybros/vendor/agents/claw` tree once cutover is complete

Important distinction:

- `claw` is the migration seed implementation
- `default` remains the bundled agent identity unless there is a separate product decision to rename the agent key, deployment key conventions, and operator-facing copy

## Transport And Process Model

### Canonical Transport

The Cybros-to-agent transport remains synchronous HTTP JSON-RPC.

Why:

- Cybros already models invocation lifecycle, callback-session authorization, replay, and drift detection around request/response RPC
- current hook calls are discrete lifecycle invocations, not a natural duplex event stream
- switching to WebSocket would force new protocol semantics for reconnect, ordering, acknowledgements, replay, and backpressure without solving the main current bottleneck

The main gain comes from:

- `WEBrick -> Puma`

not from:

- `HTTP -> WebSocket`

### Process Model

The bundled default agent should behave as a stateless concurrent HTTP service from Cybros's perspective.

Each hook call is handled as an independent HTTP request.
Puma provides concurrency and request lifecycle management.
Any Cybros callback usage still happens through explicit callback session payloads and explicit outbound HTTP requests back into Cybros.

There is no connection affinity requirement in V1.

## Component Boundaries

The implementation should follow a "Rails shell + pure Ruby agent core" split.

### Rails Shell Responsibilities

- request routing
- bearer authentication at the HTTP boundary
- JSON parsing and response rendering
- error-to-status / error-to-JSON-RPC mapping
- environment/configuration loading
- structured logging
- Puma process management

### Agent Core Responsibilities

- manifest loading
- identity construction
- prompt loading/assembly
- RPC method dispatch
- hook implementations
- attachment import translation
- callback client behavior

### Boundary Rule

Controllers stay thin.
They should not embed protocol semantics or hook logic.

Instead:

- controller -> dispatcher -> pure Ruby hook/service object

This keeps the agent logic testable without depending on a live Puma process, a Rails request object, or a database connection.

## Request Lifecycle And Error Handling

Each `POST /rpc` request should follow a stable synchronous lifecycle:

1. authenticate bearer
2. validate request shape and parse JSON-RPC payload
3. dispatch by `method`
4. execute hook/service logic
5. optionally call Cybros callback endpoints using the supplied callback session
6. return JSON-RPC `result`

Error handling should be explicit and stable.

### Error Classes

- authentication errors: invalid or missing deployment bearer
- protocol errors: malformed JSON, missing `method`, unsupported `method`, invalid params shape
- domain errors: invalid business payloads, callback-session misuse, attachment import validation failures
- unknown errors: any unexpected internal failure

### Error Boundary Rules

- do not leak raw Ruby exceptions as the public contract
- keep JSON-RPC error shapes stable and testable
- keep `/health` and `/rpc` behavior compatible with the current bundled default service
- do not move invocation replay/recovery responsibility into the bundled agent host; Cybros keeps that responsibility

## Optional Rails Subsystems

`ActiveRecord` and `ActiveJob` may remain available in the bundled Rails application, but they are optional implementation capabilities, not protocol requirements.

Approved constraint:

- the hot path for `initialize`, `agent.health`, lifecycle hooks, and callback usage must not require local database state or background job completion in order to be correct

Acceptable future uses:

- local caching
- auxiliary audit trails
- offline cleanup
- asynchronous non-critical prep work

Unacceptable V1 use:

- "return success now, finish the hook later in a background job"
- "the hook only works if a local Active Record row already exists"

## Testing Strategy

Testing should prove host replacement without protocol drift.

### Required Coverage

- existing bundled-agent RPC contract tests still pass
- manifest and identity tests still pass
- request/integration tests cover `/rpc` and `/health`
- Cybros-side programmable-agent integration tests still pass against the new host

### Important Test Boundary

Most agent-core tests should run without:

- booting Puma
- connecting to a local DB

Only host/request integration tests should need the full Rails host.

## Cutover Strategy

Cut over in three phases:

1. freeze the existing bundled default contract with tests
2. promote the `cybros/vendor/agents/claw` Rails skeleton into `cybros/agents/default` and port the existing bundled default runtime logic into it
3. switch the bundled default deployment/bootstrap path to that Rails host and delete the old WEBrick implementation artifacts plus the temporary `vendor/agents/claw` source tree

During cutover:

- keep `agent.yml`, prompts, identity fields, and deployment fingerprint rules stable unless there is a deliberate protocol reason to change them
- prefer reusing existing dispatcher/manifest/identity/hook code over rewriting behavior into controllers
- treat a rename from bundled identity `default` to bundled identity `claw` as out of scope for this cut

## Summary

The approved direction is:

- host the bundled default agent as an API-only Rails app under `cybros/agents/default`
- serve it with Puma
- keep `POST /rpc` and `GET /health` as the public surface
- keep `agent_rpc.v1` and `http_jsonrpc` unchanged
- keep Rails conveniences optional and implementation-local
- do not introduce ActionCable or WebSocket semantics into the main Cybros-to-agent path
- use `cybros/vendor/agents/claw` only as a temporary scaffold source, not as the long-lived bundled agent location
