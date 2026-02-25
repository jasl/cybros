# Cybros Monorepo

This file provides guidance to AI coding agents working with this repository.

## What is Cybros?

Cybros is an experimental AI Agent platform. The core product models agent conversations as dynamic Directed Acyclic Graphs (DAGs), with a companion execution subsystem that provides sandboxed environments for agent tool use.

**Status**: Experimental. Breaking changes are expected across all sub-projects.

## Repository Structure

This is a monorepo containing several related projects:

```
cybros/
├── cybros/        # Main product — Rails Agent service
├── nexus/         # Sandbox supervisor daemon (Go)
├── mothership/    # Dev-only lightweight Agent server for debugging Nexus (Rails)
└── references/    # Reference materials (gitignored, not committed)
```

### cybros/ — Main Product

The core Cybros platform. A Ruby on Rails application that models agent conversations as DAGs. Handles multi-tenancy, conversation management, agent orchestration, and the web UI.

- **Tech**: Ruby 4.0.1, Rails 8.2.0.alpha, PostgreSQL 18 + pgvector, Hotwire, Tailwind CSS 4 + DaisyUI 5, Bun
- **Details**: See `cybros/AGENTS.md`

```bash
cd cybros
bin/setup       # First-time setup
bin/dev         # Start dev server (port 3000)
bin/ci          # Full CI suite
```

### nexus/ — Sandbox Supervisor

A Go daemon that runs on host machines, polls a control plane for execution directives, and runs them in sandboxed environments (microVM, container, or host-level isolation).

- **Tech**: Go 1.25, cross-platform (Linux amd64/arm64, macOS arm64)
- **Details**: See `nexus/AGENTS.md`

```bash
cd nexus
make test          # Run tests
make build-macos   # Build macOS binary
make build-linux   # Build Linux binaries
```

### mothership/ — Dev Agent Server

A minimal Rails application that implements the Conduits control plane API. Used exclusively for local development and debugging of Nexus — not a production service.

- **Tech**: Ruby 4.0.1, Rails 8.1.2, PostgreSQL, Importmap
- **Details**: See `mothership/AGENTS.md`

```bash
cd mothership
bin/setup              # First-time setup
bin/rails server       # Start on port 3000
```

### references/ — Reference Materials

Contains third-party codebases and documentation for reference. **This directory is gitignored and must never be committed.**

## How the Projects Relate

```
┌─────────────────────────────────────────────┐
│                  Cybros (Rails)              │
│  Agent platform, DAG engine, web UI         │
│  Produces directives for execution          │
└──────────────────┬──────────────────────────┘
                   │ Conduits API (HTTP)
                   ▼
┌──────────────────────────────────────────────┐
│                  Nexus (Go)                  │
│  Polls for directives, executes in sandbox   │
│  Reports results back                        │
└──────────────────────────────────────────────┘

For local Nexus development, Mothership substitutes for Cybros
as a lightweight control plane implementing the same Conduits API.
```

Communication is **pull-based**: Nexus polls the control plane (Cybros or Mothership) via `POST /conduits/v1/polls`. No inbound ports are required on the Nexus side.

## Cross-Project Conventions

### Languages & Formatting

| Project | Language | Formatter | Linter |
|---------|----------|-----------|--------|
| cybros | Ruby + JS | editorconfig (2-space) | RuboCop (omakase) |
| nexus | Go | `gofmt` (tabs) | `go vet` |
| mothership | Ruby | editorconfig (2-space) | RuboCop (omakase) |

### Shared Principles

- **UUIDv7 primary keys** across all databases
- **Multi-tenancy by Account** — all resources are scoped by `account_id`
- **Contract-first protocol** — Conduits API schemas in `nexus/docs/protocol/` are the source of truth; change schemas before code
- **Pull-based communication** — Nexus pulls work from the control plane; no inbound ports needed
- **Database-backed infrastructure** — Solid Queue/Cache/Cable in Rails apps (no Redis dependency)

### Working Across Projects

When making changes to the Conduits protocol (the API between Nexus and its control plane):

1. Update the OpenAPI spec in `nexus/docs/protocol/`
2. Update Go types in `nexus/protocol/`
3. Update Rails controllers/models in `mothership/` (and `cybros/` when applicable)
4. Run tests in both Go and Rails projects

## Environment Notes

- Ruby projects use Bundler for gems and Bun (cybros) or Importmap (mothership) for JS
- Go project uses standard Go modules
- All Rails apps expect PostgreSQL
- Development credentials: see each project's AGENTS.md
