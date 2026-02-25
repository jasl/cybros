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

| Method | Path | Description |
|--------|------|-------------|
| POST | `/conduits/v1/polls` | Long-poll for directives |
| POST | `/conduits/v1/territories/enroll` | Register new territory |
| POST | `/conduits/v1/directives/:id/started` | Report directive started |
| POST | `/conduits/v1/directives/:id/heartbeat` | Renew lease / report progress |
| POST | `/conduits/v1/directives/:id/log_chunks` | Upload stdout/stderr chunks |
| POST | `/conduits/v1/directives/:id/finished` | Report directive completed |

### Mothership API (Human-facing)

Simple web UI and API for managing territories, directives, facilities, and policies:

- Territory management (list, show, enrollment tokens)
- Directive management (create, approve/reject, view logs)
- Facility management
- Policy management

### Key Domain Models

All under the `Conduits::` namespace:

- **Territory** — A registered Nexus instance
- **Facility** — A persistent workspace on a territory
- **Directive** — A unit of execution (command + facility + capabilities + timeout)
- **Policy** — Capability policies scoped at global/account/user/facility level
- **EnrollmentToken** — One-time tokens for territory registration
- **LogChunk** — Captured stdout/stderr from directive execution
- **AuditEvent** — Audit trail for all state changes

State machines (via AASM):
- Directive: `pending → approved → claimed → started → finished/failed/timed_out`
- Territory: `pending → enrolled → active / suspended`

### Authentication

- Nexus authenticates via `X-Nexus-Territory-Id` header (dev mode) or mTLS (future)
- Directive-scoped operations use `Authorization: Bearer <directive_token>` (JWT)
- Enrollment endpoint is rate-limited (via Rack::Attack)

## Code Style

- RuboCop with `rubocop-rails-omakase` config
- 2-space indentation (Ruby), LF line endings
- Follow existing patterns in the codebase

## Relationship to Other Projects

- **Nexus** (`../nexus/`) — The client that polls this server. Protocol schemas live in `nexus/docs/protocol/`
- **Cybros** (`../cybros/`) — The production control plane. Mothership mirrors its Conduits API surface for dev purposes
