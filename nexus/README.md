# Cybros Nexus

Monorepo for the **Cybros Execution Subsystem** — a sandbox service designed for AI Agent workloads.

- `mothership/` — Control plane (Ruby on Rails 8.1). Manages missions, executors, workspaces, and scheduling.
- `client/`, `config/`, `daemon/`, `logstream/`, `netpolicy/`, `protocol/`, `sandbox/`, `version/` — Shared Go packages (at module root): protocol types, Mothership client, network allowlist, log streaming, sandbox driver abstraction.
- `nexus-linux/` — Linux Nexus daemon (Go). Targets **x86_64 + aarch64** (2024+ distros). Will support microVM isolation and hard egress control.
- `nexus-macos/` — macOS Nexus daemon (Go). **Apple Silicon only**, `darwin-automation` profile only (no container/isolation).
- `docs/` — Design documents, protocol schemas.
- `tools/` — Build utilities.

> **Go 1.26** (2026-02-10) · **Rails 8.1.2** (2026-01-08) · **Ruby 4.0.1**

---

## Directory Structure

```
client/               # HTTP client for Mothership
config/               # YAML configuration
daemon/               # Main service loop
logstream/            # Stdout/stderr streaming
netpolicy/            # Network allowlist parsing
protocol/             # Protocol types (DirectiveSpec, etc.)
sandbox/              # Sandbox driver interface + host driver
version/              # Build-time version
docs/
  execution_subsystem_design.md
  protocol/
    directivespec_capabilities_net.schema.v1.json
    conduits_api_openapi.yaml
mothership/
  app/ config/ db/ ...
nexus-linux/
  cmd/nexusd/
  cmd/nexus-helper/
  packaging/systemd/
nexus-macos/
  cmd/nexusd/
  packaging/launchd/
tools/
  sync_schema.sh
Makefile
go.mod
```

---

## Quick Start

### Mothership (Rails)

```bash
cd mothership
bundle install
bin/rails db:create db:migrate
bin/rails server
```

Phase 1 minimal UI (HTML):
- `/mothership/territories`
- `/mothership/directives`

### Nexus (Go)

Build Linux:

```bash
make build-linux
./dist/nexusd-linux-amd64 -config ./nexus-linux/config.example.yaml
```

Build macOS:

```bash
make build-macos
./dist/nexusd-macos-arm64 -config ./nexus-macos/config.example.yaml
```

Note: `bin/rails server` runs over HTTP by default, so local dev should use `http://localhost:3000` unless you terminate TLS in front of Rails.

### Enrollment (mTLS client cert issuance; optional)

```bash
./dist/nexusd-linux-amd64 -config ./nexus-linux/config.example.yaml -enroll-token "<token>" -enroll-with-csr=true -enroll-out-dir ./nexus-credentials
```

### Other Commands

```bash
make tidy          # go mod tidy
make fmt           # gofmt all Go files
make test          # go test ./...
make sync-schema   # sync JSON schema from docs/ to protocol/schema/
```

---

## Development Conventions

- **Contract-first**: `docs/protocol/*.json/*.yaml` is the source of truth. Change the contract before changing code.
- **Security boundaries**: Nexus Go code follows least-privilege separation (`nexusd` unprivileged + `nexus-helper` minimal privilege). Hard isolation and egress control are only available in Untrusted (microVM) profile on Linux.
- **Cross-platform consistency**: Allowlist parsing/matching logic (`domain:port` + `*.` wildcard) must behave identically in Go and Ruby. This repo provides isomorphic implementations and test vectors.

---

## License

Placeholder: replace with your license of choice (MIT / Apache-2.0 / commercial).
