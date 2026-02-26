# Mothership

This file provides guidance to AI coding agents working with this sub-project.

## What is Mothership?

Mothership is a **development-only** lightweight Rails application that implements the Conduits control plane API. It serves as a stand-in for the full Cybros platform when developing and debugging Nexus locally.

**This is not a production service.** It exists solely to give Nexus something to talk to during development.

## Development Commands

```bash
bin/setup              # Initial setup (gems, DB creation, schema load)
bin/rails server       # Start dev server on port 3000
bin/rails test         # Run tests
bin/rails db:migrate   # Run migrations
bin/rails db:reset     # Drop, create, load schema
```

## Technology Stack

- **Backend**: Ruby 4.0.1, Rails 8.1.2
- **Database**: PostgreSQL
- **Background Jobs**: Solid Queue (database-backed)
- **Frontend**: Hotwire (Turbo + Stimulus), Importmap, Propshaft
- **Primary Keys**: UUIDv7

## Architecture

### Conduits API (Nexus-facing)

The core purpose of Mothership — implements the polling/reporting API that Nexus communicates with:

**Directive track** (code execution):

| Method | Path | Description |
|--------|------|-------------|
| POST | `/conduits/v1/polls` | Long-poll for directives |
| POST | `/conduits/v1/territories/enroll` | Register new territory (with kind, platform, display_name) |
| POST | `/conduits/v1/territories/heartbeat` | Territory-level presence, capability, and bridge entity reporting |
| POST | `/conduits/v1/directives/:id/started` | Report directive started |
| POST | `/conduits/v1/directives/:id/heartbeat` | Renew lease / report progress |
| POST | `/conduits/v1/directives/:id/log_chunks` | Upload stdout/stderr chunks |
| POST | `/conduits/v1/directives/:id/finished` | Report directive completed |

**Command track** (device capabilities):

| Method | Path | Description |
|--------|------|-------------|
| GET | `/conduits/v1/commands/pending` | Poll for pending commands (REST fallback) |
| POST | `/conduits/v1/commands/:id/result` | Submit command execution result |
| POST | `/conduits/v1/commands/:id/cancel` | Cancel a command |

**WebSocket** (Action Cable):

| Channel | Description |
|---------|-------------|
| `Conduits::TerritoryChannel` | Real-time push for commands and directive wake-ups |

### Mothership API (Human-facing)

Simple web UI and API for managing territories, directives, facilities, and policies:

- Territory management (list, show, enrollment tokens)
- Directive management (create, approve/reject, view logs)
- Facility management
- Policy management

### Key Domain Models

All under the `Conduits::` namespace:

- **Territory** — A registered Nexus instance (kind: `server`, `desktop`, `mobile`, `bridge`)
- **Facility** — A persistent workspace on a territory
- **Directive** — A unit of execution: command + facility + capabilities + timeout (directive track)
- **Command** — A device-capability invocation: capability + params + timeout (command track)
- **BridgeEntity** — A sub-device managed by a bridge territory (e.g. light, sensor, camera)
- **Policy** — Capability policies scoped at global/account/user/facility level, plus device access policies
- **EnrollmentToken** — One-time tokens for territory registration
- **LogChunk** — Captured stdout/stderr from directive execution
- **AuditEvent** — Audit trail for all state changes (directives and commands)

State machines (via AASM):
- Directive: `pending → approved → claimed → started → finished/failed/timed_out`
- Command: `queued → dispatched → completed/failed/timed_out/canceled`
- Territory: `pending → enrolled → active / suspended`

### Authentication

- Nexus authenticates via mTLS client certificate fingerprint (`X-Nexus-Client-Cert-Fingerprint` header) or `X-Nexus-Territory-Id` header (dev mode). Configurable via `CONDUITS_TERRITORY_AUTH_MODE` (mtls/header/either).
- WebSocket (Action Cable) connections authenticate via mTLS fingerprint (production) or territory ID (dev/test)
- Directive-scoped operations use `Authorization: Bearer <directive_token>` (JWT)
- Enrollment endpoint is rate-limited (via Rack::Attack)

### Key Services

- **CommandDispatcher** — Three-tier dispatch: WebSocket (preferred) → push notification → REST poll fallback
- **CommandTargetResolver** — Resolves target territory and optional bridge entity for commands by capability, location, tag, or direct ID
- **BridgeEntitySyncService** — Full-reconcile sync of bridge entities from territory heartbeat data
- **DirectiveNotifier** — Broadcasts wake-up notifications to WebSocket-connected territories when directives are available
- **PolicyResolver** — Merges layered policies (global → account → user → facility) including device access rules

## Code Style

- RuboCop with `rubocop-rails-omakase` config
- 2-space indentation (Ruby), LF line endings
- Follow existing patterns in the codebase

## Relationship to Other Projects

- **Nexus** (`../nexus/`) — The client that polls this server. Protocol schemas live in `nexus/docs/protocol/`
- **Cybros** (`../cybros/`) — The production control plane. Mothership mirrors its Conduits API surface for dev purposes
