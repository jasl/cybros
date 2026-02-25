# AGENTS.md — Cybros Nexus

> Part of the Cybros monorepo. See `../AGENTS.md` for the overall repository guide.

## Project Overview

Cybros Nexus is a sandbox execution service for AI Agents. It provides isolated environments where Agents can run commands, access facilities (persistent workspaces), and produce artifacts — with configurable security boundaries.

**Status**: Experimental prototype. Breaking changes are expected and encouraged for better design.

## Architecture

```
┌─────────────┐         ┌──────────────┐
│  Control     │◄────────│    Nexus      │
│  Plane       │  HTTP   │  (Go daemon)  │
│  (Cybros or  │  Poll   │  Sandbox      │
│  Mothership) │─────────►  Territory    │
└─────────────┘         └──────────────┘
```

- **Control Plane** (`../cybros/` in production, `../mothership/` for dev): Rails app that manages directives, territories, facilities, scheduling, and approval workflows.
- **Nexus** (this directory — shared Go packages at root + `nexus-linux/`, `nexus-macos/`): Go daemon that polls the control plane for directives and executes them in sandboxed environments.

Communication is **pull-based**: Nexus polls the control plane for work via `POST /conduits/v1/polls`. No inbound ports needed on the territory side.

## Key Terminology

| Term | Description |
|------|-------------|
| **Directive** | A unit of execution: a command to run with a facility, capabilities, and timeout. Rails model: `Conduits::Directive`. |
| **Territory** | A registered Nexus instance (execution node). Authenticated via mTLS. Rails model: `Conduits::Territory`. |
| **Facility** | A persistent working directory attached to a territory. Rails model: `Conduits::Facility`. |
| **Account** | A tenant. All Conduits resources are scoped by account for multi-tenancy isolation. |
| **Sandbox Profile** | The isolation level: `untrusted` (microVM), `trusted` (container), `host` (no isolation), `darwin-automation` (macOS only). |
| **Conduits** | The module namespace for the execution subsystem, and the API namespace for Nexus ↔ Mothership communication (`/conduits/v1/`). |

## Directory Structure

```
nexus/                         # This directory (Go module root)
├── AGENTS.md                  # This file
├── README.md                  # Project overview and quick start
├── Makefile                   # Go build targets
├── go.mod                     # Go module: cybros.ai/nexus
│
├── docs/
│   ├── execution_subsystem_design.md   # Full design document
│   ├── design/                         # Split design docs (7 topic files + index)
│   └── protocol/
│       ├── conduits_api_openapi.yaml                        # OpenAPI spec for Conduits API
│       └── directivespec_capabilities_net.schema.v1.json    # Network capability JSON Schema
│
├── client/                    # Go: HTTP client for control plane communication
├── config/                    # Go: YAML configuration management
├── daemon/                    # Go: Main service: poll loop, directive handling
├── egressproxy/               # Go: Network egress proxy
├── enroll/                    # Go: mTLS enrollment
├── internal/                  # Go: Internal packages
├── logstream/                 # Go: Stdout/stderr streaming and upload
├── netpolicy/                 # Go: Network allowlist parsing (domain:port)
├── protocol/                  # Go: Protocol types (DirectiveSpec, DirectiveLease, etc.)
│   └── schema/                # Synced JSON Schema files
├── rootfs/                    # Go: Root filesystem utilities
├── sandbox/                   # Go: Sandbox driver interface
│   └── host/                  # MVP host driver (no isolation)
├── version/                   # Go: Build-time version string
│
├── nexus-linux/               # Linux-specific entry points
│   ├── cmd/nexusd/            # Main daemon binary
│   ├── cmd/nexus-helper/      # Privileged helper (skeleton)
│   └── packaging/systemd/     # systemd service files
│
├── nexus-macos/               # macOS-specific entry points
│   ├── cmd/nexusd/            # Main daemon binary
│   └── packaging/launchd/     # launchd plist
│
└── tools/
    └── sync_schema.sh         # Sync JSON schema from docs/ to protocol/schema/
```

> **Monorepo note**: The Rails control plane (Mothership) now lives at `../mothership/`. See `../mothership/AGENTS.md` for its own documentation.

## Technology Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| Nexus daemon | Go | 1.25 |
| Go module path | `cybros.ai/nexus` | - |
| Control plane (Mothership) | Ruby on Rails | 8.1.2 (see `../mothership/`) |

## Development Workflow

### Contract-First

Protocol schemas in `docs/protocol/` are the source of truth. Change the schema first, then update code.

### Build & Test

```bash
# Go (from nexus/)
make tidy              # go mod tidy
make test              # go test ./...
make build-macos       # build macOS binary
make build-linux       # build Linux binaries (amd64 + arm64)

# Mothership (from ../mothership/)
cd ../mothership
bundle install
bin/rails db:create db:migrate
bin/rails test
bin/rails server       # Start dev server on :3000
```

### API Endpoints (Conduits V1)

| Method | Path | Description |
|--------|------|-------------|
| POST | `/conduits/v1/polls` | Long-poll for directives |
| POST | `/conduits/v1/territories/enroll` | Register new territory (mTLS enrollment) |
| POST | `/conduits/v1/directives/:id/started` | Report directive started |
| POST | `/conduits/v1/directives/:id/heartbeat` | Renew lease / report progress |
| POST | `/conduits/v1/directives/:id/log_chunks` | Upload stdout/stderr chunks |
| POST | `/conduits/v1/directives/:id/finished` | Report directive completed |

### Authentication

- Nexus authenticates to Mothership via mTLS (future) or `X-Nexus-Territory-Id` header (dev mode).
- Directive-scoped operations use `Authorization: Bearer <directive_token>`.

## Design Decisions

1. **Pull model**: Nexus polls for work — no inbound ports, NAT/firewall friendly.
2. **Deny-by-default**: Network access is denied unless explicitly allowed via allowlist.
3. **Privilege separation**: `nexusd` runs unprivileged; `nexus-helper` handles minimal privileged operations.
4. **Cross-platform consistency**: Allowlist parsing logic must behave identically in Go and Ruby.
5. **MVP scope**: Only the host driver (no isolation) is implemented. MicroVM and container drivers are future work.
6. **UUIDv7 primary keys**: All tables use UUID primary keys for cross-instance compatibility.

## Code Style

- **Go**: Standard `gofmt` formatting. Run `make fmt` before committing.
- **Ruby**: RuboCop with `rubocop-rails-omakase` config. Run `bin/rubocop` before committing.
- **Immutability**: Prefer creating new objects over mutation.
- **Small files**: Keep files under 400 lines. Extract utilities when files grow.
- **Error handling**: Always handle errors. Never swallow errors silently.

## Important Files for Modifications

When modifying the protocol:
1. Update `docs/protocol/` schemas first
2. Run `make sync-schema` to copy to Go package
3. Update `protocol/types.go` (Go types)
4. Update Rails models/controllers as needed
5. Verify both sides compile and tests pass

When adding a new sandbox driver:
1. Implement `sandbox.Driver` interface in a new package under `sandbox/`
2. Wire it up in `daemon/service.go`
3. Add the profile name to config and supported_sandbox_profiles

## Data Model (Rails)

```
Account (global)                    # Multi-tenancy root
  ├── User                          # belongs_to :account (optional)
  ├── Conduits::Policy              # Scoped capability policy (global/account/user/facility)
  │
  └── Conduits::Territory           # Execution node
        ├── Conduits::Facility      # Persistent workspace
        │     └── Conduits::Directive  # Unit of execution
        └── Conduits::Directive
```

Tables use `conduits_` prefix: `conduits_territories`, `conduits_facilities`, `conduits_directives`, `conduits_policies`.
