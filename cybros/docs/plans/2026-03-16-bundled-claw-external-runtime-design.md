# Bundled Claw External Runtime Design

## Status

Approved on 2026-03-16 for immediate implementation.

## Problem

The bundled default `claw` agent is currently modeled as an HTTP JSON-RPC deployment in the database, but the default bootstrap path still starts an in-process host from the main `cybros` Rails app.

That hybrid model causes three problems:

- bare-metal `bin/dev` and Docker Compose do not share the same runtime topology
- connection and recovery behavior are harder to reason about because the app can silently recreate the runtime
- the database appears to describe an external deployment, while the real source of truth is partly hidden inside the `cybros` process

## Goals

- make bundled default `claw` a real external process in all supported environments
- wire `bin/dev` so the full local suite starts with one command
- wire official Compose flows so `claw` runs as a separate service
- keep the bundled default connection state persisted in the database
- make bootstrap reconcile the default bundled agent against environment-specific desired connection settings
- delete obsolete in-process host and managed-local recovery paths

## Non-Goals

- no support for hot-path ENV overrides during RPC calls
- no environment auto-detection heuristics inside the RPC client
- no compatibility layer preserving the old in-process bundled host behavior

## Core Decision

The bundled default `claw` runtime becomes a system-managed external deployment.

`cybros` will:

- persist runtime connection details in the `agents` table
- reconcile those details during bundled bootstrap
- call the runtime through normal HTTP JSON-RPC only

`cybros` will not:

- start a bundled host in-process
- keep an in-memory host registry
- silently recover by spawning a new local runtime during RPC retries

## Source Of Truth

Runtime reads use the database only.

- `Agents::RPCClient` reads `endpoint_url`, `deployment_bearer_secret_ref`, `deployment_fingerprint`, and related runtime metadata from the persisted `Agent`
- environment variables participate only in bundled default bootstrap/reconcile
- bootstrap treats environment variables as the desired state for the default bundled `claw` agent and writes the reconciled values into the database

This yields a clear priority model:

1. bootstrap-time ENV is the desired input for the bundled default agent
2. bootstrap persists reconciled state into the database
3. runtime reads use the database only

## Default Agent Special-Case

The bundled default `claw` agent remains intentionally special-cased.

That special treatment is limited to:

- bundled bootstrap/reconcile
- stable workspace path resolution
- official local and Compose startup defaults

Non-default agents do not read these bootstrap environment variables and continue to use their persisted configuration directly.

## Workspace Model

The bundled default `claw` workspace becomes a stable path rather than an `agent.id`-derived path.

Recommended path shape:

- bundled default `claw`: `<agent_workspace_root>/bundled/claw`
- conversation workspaces remain under the existing conversation workspace subtree

This lets:

- the external `claw` service mount and use a predictable live workspace
- `cybros` keep prompt/skill/bootstrap files synchronized in the same location
- bare-metal and Compose share the same semantics without depending on DB-generated IDs

## Configuration Model

The default bundled bootstrap reads explicit desired-state variables:

- `CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL`
- `CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER`
- `CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT`

The external `claw` process reads its own runtime configuration:

- `PORT`
- `CLAW_REQUIRED_BEARER`
- `CLAW_DEPLOYMENT_FINGERPRINT`
- `CLAW_WORKSPACE_ROOT`

Bare-metal and Compose differ only by the values passed into those variables.

## Startup Topology

### Bare-Metal

`Procfile.dev` starts:

- `web`
- `job`
- `js`
- `css`
- `claw`

The `claw` entry runs the bundled `agents/claw` Rails app on a fixed local port and points it at the stable bundled workspace root.

### Docker Compose

Official Compose templates add a dedicated `claw` service.

- `app` and `jobs` connect to the `claw` service through its service DNS name
- `app`, `jobs`, and `claw` share the same bundled workspace volume
- bearer and fingerprint values are passed explicitly to both sides

## Failure And Recovery Semantics

Failure means the persisted deployment is unreachable or unhealthy.

Allowed recovery paths:

- restart the external `claw` process
- rerun bundled bootstrap/reconcile so the database matches the current environment

Disallowed recovery paths:

- implicit in-process host startup
- RPC retry code that spawns or rehosts the runtime

## Testing Strategy

Tests should shift from “host gets started in-process” to “bootstrap persists the correct external deployment state”.

Coverage should include:

- service tests for bootstrap reconcile behavior
- path tests for stable bundled workspace resolution
- `Procfile.dev` and Compose template tests for explicit `claw` process wiring
- `agents/claw` RPC contract tests for the standalone service
- end-to-end verification through `bin/e2e`, `bin/ci_e2e`, local `bin/dev`, and Docker Compose

Test-only HTTP harnesses may still exist, but only as test support. Application production code must not embed bundled host startup.
