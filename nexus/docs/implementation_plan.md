# Implementation Plan & Progress Tracker

Based on the [design document](design/README.md) roadmap (Phase 0-7).
Reference analysis and decision log: [07_reference_analysis.md](design/07_reference_analysis.md)

## Current Status: Phase 7 (7a-7c) ✓ — Universal Device Abstraction

Phase 0 E2E: `cd mothership && RAILS_ENV=test bin/rails test test/integration/conduits_e2e_test.rb`

---

## Phase 0: Protocol Freeze + Minimal End-to-End Loop ✓

> Goal: Freeze protocol schemas, establish data model and state machine, prove the enroll-poll-execute-upload loop works.

All Phase 0 tasks complete:

- **Protocol & Schema**: DirectiveSpec/DirectiveLease types frozen, OpenAPI spec (`docs/protocol/conduits_api_openapi.yaml`), JSON capability schemas, Go types (`protocol/types.go`). Design decisions D1-D15 documented in [design docs](design/).
- **Data Model (Rails)**: Account, User, Territory, Facility, Directive, Policy models; PostgreSQL with UUIDv7; DB-backed log chunks; ActiveStorage for diff blobs.
- **API Endpoints**: 7 Conduits API endpoints (enroll, territory heartbeat, polls, started, heartbeat, log_chunks, finished) + user-facing log_chunks reader. mTLS auth (default) + dev header auth (`X-Nexus-Territory-Id`). JWT directive tokens. Lease TTL reaper via SolidQueue.
- **Go Nexus**: Config (`config/`), HTTP client (`client/`), poll loop, log uploader (`logstream/`), host sandbox driver (`sandbox/host/`), network allowlist parser (`netpolicy/`), enroll flow (`enroll/`), territory/directive heartbeat, facility prepare (auto-clone), standard env injection.
- **Verification**: E2E runner, SolidQueue scheduler, OpenAPI contract smoke tests.

---

## Phase 1: Linux Untrusted (bubblewrap) + Trusted (Container) MVP ✓

> Goal: Untrusted runs inside bubblewrap with hard egress enforcement (UDS proxy + allowlist). Trusted runs inside rootless container. Standard Ubuntu 24.04 userspace (amd64+arm64).

### Phase 1a: bubblewrap + egress proxy ✓

- **Plumbing**: Driver factory pattern (`sandbox/factory.go`), capabilities plumbing, facility locking (`syscall.Flock`), `nexusd -doctor`.
- **Rootfs**: Ubuntu 24.04 minimal rootfs (amd64+arm64), sha256 verification, cache/reuse (`rootfs/`).
- **Untrusted sandbox**: bwrap driver (`sandbox/bwrap/`), read-only rootfs + rw `/workspace`, `--unshare-net`, embedded egress proxy (`egressproxy/` — HTTP/CONNECT + SOCKS5, UDS + TCP), socat bridge, JSONL audit.

### Phase 1b: container driver ✓

- **Trusted sandbox**: Podman rootless container (`sandbox/container/`), per-directive TCP proxy, `--cap-drop=ALL`, `--security-opt=no-new-privileges`.
- **Outputs**: git diff (max 1 MiB), minimal Rails UI (territory list, directive list, log viewer, diff download), overflow disk capture (`.nexus/overflow/`), debug tape (JSONL + rotation).

Phase 1 hardening audit: 7 CRITICAL, 4 HIGH, 4 MEDIUM — all fixed with regression tests.

---

## Phase 2: Policy / Approval / Audit ✓

### Phase 2a: Core Policy Engine ✓

FsPolicyV1 (prefix-based, path traversal protection), ApprovalEvaluator (3-tier Codex-style), `awaiting_approval` state, hierarchical merge (global→Account→User→Facility), PolicyResolver, wired into create + poll re-validation, Policy CRUD API, self-approval prevention.

### Phase 2b: Audit & Observability ✓

AuditEvent model (12 event types), AuditService (error-isolated), 8 instrumented decision points, execution timing telemetry (`time_to_start_ms`, `total_duration_ms`), 90-day cleanup job.

### Phase 2c: Enforcement Hardening ✓

CommandValidator (two-tier: FORBIDDEN_PATTERNS + APPROVAL_PATTERNS), Landlock skeleton (`sandbox/landlock/` — raw syscalls, ABI v1+, `FromFsCapability` helper), FsCapability `WritableRoots`/`ReadOnlySubpaths` (Go types + JSON schema).

---

## Phase 3: Linux Untrusted Hardened (Optional Firecracker microVM) ✓

> Design doc: [`docs/design/08_firecracker.md`](design/08_firecracker.md)
> Networking: vsock + egress proxy (no TAP/nftables, no root required)

- **Plumbing**: `untrusted_driver` config selector, DriverFactory configurable, conditional driver registration, doctor checks (KVM, firecracker, e2fsprogs).
- **Firecracker driver** (`sandbox/firecracker/`): 3-drive model (rootfs + cmd + workspace), vsock bridge (`egressproxy/vsock_bridge.go`), VM config JSON, guest wrapper, ext4 block devices (`mke2fs -d` + `fuse2fs`), Ubuntu 24.04 baseline image (`tools/build-fc-rootfs.sh`).
- Phase 3 audit: poll profile source alignment, nexus-init `reboot -f` (x86_64 pci=off), workspace extraction warnings, rootfs builder socat error check.

---

## Phase 4: Linux Untrusted microVM (NET=ALLOWLIST + Hard Egress)

| Task | Status | Notes |
|------|--------|-------|
| nexus-helper (privileged, minimal) | TODO | Skeleton in `nexus-linux/cmd/nexus-helper/` |
| TAP/netns/nftables setup | TODO | |
| Egress proxy: microVM enforcement wiring | TODO | Phase 1 builds the proxy; Phase 4 forces all microVM egress through it |
| Proxy admin API for debugging | TODO | Reference: Codex proxy admin endpoint |
| DNS audit logging in proxy | TODO | Reference: Gap #3. Record qname/answers/ttl |
| SNI consistency check (optional) | TODO | |

---

## Phase 5: macOS darwin-automation ✓

- darwin-automation driver (`sandbox/darwinautomation/` — `/bin/zsh`, process group mgmt), TCC permission detection (`tcc_darwin.go`), shared CWD resolution (`sandbox/cwd.go`), build tag split (linux/darwin/other), factory + daemon integration, macOS doctor checks (osascript + shortcuts).

---

## Phase 6: Production Readiness (partial ✓)

### 6a: Observability ✓

| Task | Notes |
|------|-------|
| slog migration | All `log.Printf` → `log/slog` across 5 files (daemon, egressproxy, cli) |
| Build metadata | `version/version.go`: Version/Commit/BuildDate via ldflags; `version.Compare()` for semver |
| Prometheus metrics | `daemon/metrics.go`: 7 metrics (struct-based, per-registry) |
| HTTP observability server | `daemon/httpserver.go`: `/healthz`, `/readyz`, `/metrics` on configurable `:9090` |

### 6b: Reliability ✓

| Task | Notes |
|------|-------|
| Graceful shutdown timeout | `config.ShutdownTimeout` (default 60s) + timer-based wg.Wait |
| Finished WAL (crash recovery) | `daemon/wal.go`: JSONL persistence, startup replay, 2MB scanner buffer |
| Circuit breaker (poll loop) | `daemon/circuitbreaker.go`: closed/open/half-open, exponential backoff |
| Disk space monitoring | `daemon/helpers.go`: `checkDiskSpace()` + 1 GiB threshold pre-check |

### 6c: Resource Governance (partial)

| Task | Status | Notes |
|------|--------|-------|
| cgroup v2 CPU/memory limits (Linux) | ✓ | `sandbox/cgroup_linux.go` + `cgroup_other.go`: fail-closed, regex validation, bounds check |
| Version negotiation (heartbeat) | ✓ | `version.Compare()` numeric semver; checks upgrade_available + min_compatible_version |
| Config env var substitution | ✓ | `os.ExpandEnv()` in `LoadFile()`; supports `${ENV_VAR}` in YAML |
| macOS code signing | ✓ | Makefile: `sign-macos-dev` (ad-hoc), `sign-macos-release` (Developer ID), `notarize-macos` |

### Phase 6 Refactoring

`daemon/service.go` split (1118 → 5 files):

| File | Lines | Content |
|------|-------|---------|
| `daemon/service.go` | 299 | Service struct, New(), Serve(), Ready(), rejectDirective(), replayWAL() |
| `daemon/directive.go` | 451 | handleDirective(), prepareFacility(), collectDiff() |
| `daemon/heartbeat.go` | 167 | tokenHolder, runTerritoryHeartbeatLoop(), runHeartbeatLoop() |
| `daemon/retry.go` | 105 | postWithRetry(), retryDelay(), sleepCtx(), cappedDuration() |
| `daemon/helpers.go` | 145 | checkDiskSpace(), isValidFacilityID(), buildDirectiveEnv(), minimalExecEnv() |

Phase 6 audit: 15 findings (C1-C3, H1-H7, M1-M3, M5, M9) — all fixed with tests.

---

## Phase 7: Universal Device Abstraction (7a-7c ✓, 7d deferred)

> Design doc: [`docs/design/09_nexus_universal_device.md`](design/09_nexus_universal_device.md)
> Goal: Generalize Nexus from "code execution engine" to "unified device capability proxy" via Territory kinds, Command track, Bridge pattern, and WebSocket push.

### Phase 7a: Data Model & Territory Extensions ✓

| Task | Notes |
|------|-------|
| Territory kind column (`server\|desktop\|mobile\|bridge`) | Enum column, NOT NULL, validated |
| Territory device fields | platform, display_name, location, tags (jsonb GIN), capabilities (jsonb GIN), websocket_connected_at, push_token/push_platform |
| BridgeEntity model | Separate table, territory FK, entity_ref (unique per territory), entity_type, capabilities (GIN), location, state, available |
| Command model (AASM) | queued → dispatched → completed/failed/timed_out/canceled, has_one_attached :result_attachment, timeout_seconds validation |
| AuditEvent command FK | command_id column, command event types in EVENT_TYPES |
| Device Policy dimension | `device` jsonb column on conduits_policies, DevicePolicyV1 (allowed/denied/approval_required with wildcard matching), merge via intersection/union semantics |
| Territory scopes | with_capability, with_capability_matching, at_location (LIKE-safe), with_tag, websocket_connected, command_capable, directive_capable |
| BridgeEntity scopes | available, of_type, with_capability, at_location (LIKE-safe) |
| Enrollment: kind/platform/display_name params | Backward-compatible, defaults to kind=server |
| Heartbeat: capabilities + bridge_entities sync | BridgeEntitySyncService full-reconcile (transactional) |

### Phase 7b: Command REST API ✓

| Task | Notes |
|------|-------|
| CommandTargetResolver | Direct territory_id → capability+location+tag → bridge entity search; deterministic ordering (last_heartbeat_at/last_seen_at DESC) |
| `GET /conduits/v1/commands/pending` | FOR UPDATE SKIP LOCKED (race-safe), AASM::InvalidTransition rescue |
| `POST /conduits/v1/commands/:id/result` | JSON result + base64 attachment, idempotent duplicate handling |
| `POST /conduits/v1/commands/:id/cancel` | Cancel queued/dispatched, already-terminal idempotent |
| CommandTimeoutJob | Reaps expired commands via Command.expired scope, audit events |
| E2E test: mobile + bridge + legacy directive flows | 7 integration tests covering full lifecycle |

### Phase 7c: WebSocket Push Channel ✓

| Task | Notes |
|------|-------|
| Action Cable Connection (dual auth) | mTLS fingerprint (query param) + territory_id header/param (dev) |
| TerritoryChannel | stream_for territory, websocket_connected_at tracking, command_result action (base64 error handling) |
| CommandDispatcher (3-tier) | WebSocket → Push Notification (mocked) → REST Poll; returns dispatch method symbol; error handling with fallback |

### Phase 7 Post-Implementation Audit

Comprehensive audit performed (2026-02-27). Findings and fixes:

| Severity | Finding | Fix |
|----------|---------|-----|
| CRITICAL | Missing `device` column on conduits_policies | Migration 20260227000005, Policy model validation + merge_device!, DevicePolicyV1 updated |
| HIGH | Race condition in pending command dispatch | FOR UPDATE SKIP LOCKED + AASM::InvalidTransition rescue |
| HIGH | CommandDispatcher no error handling | dispatch! before broadcast, rescue with fallback, return value |
| MEDIUM | BridgeEntitySyncService no transaction | Wrapped in ActiveRecord::Base.transaction |
| MEDIUM | LIKE wildcard injection in at_location | sanitize_sql_like() in Territory + BridgeEntity scopes |
| MEDIUM | Non-deterministic target selection | ORDER BY last_heartbeat_at/last_seen_at DESC, id ASC |
| MEDIUM | Base64 error handling in TerritoryChannel | ArgumentError rescue, AASM::InvalidTransition rescue |

### Phase 7 Test Coverage

| Test File | Tests | Focus |
|-----------|-------|-------|
| territory_device_test.rb | 15 | Kind, capabilities, scopes, heartbeat |
| bridge_entity_test.rb | 7 | Validation, scopes, bridge-only constraint |
| command_test.rb | 12 | AASM, validation, capability checks, expired scope |
| device_policy_v1_test.rb | 14 | Pattern matching, merge semantics, real Policy records |
| bridge_entity_sync_service_test.rb | 5 | Upsert, reconcile, mark unavailable |
| command_target_resolver_test.rb | 7 | Direct, capability, location, tag, bridge, priority |
| command_dispatcher_test.rb | 5 | WebSocket, push, poll, AASM error handling |
| command_timeout_job_test.rb | 5 | Expired reaping, non-expired skip, audit events |
| conduits_command_e2e_test.rb | 7 | Full lifecycle (mobile, bridge, legacy directive) |
| policy_test.rb | +4 | Device dimension validation and merge |
| **Total new** | **81** | |

### Phase 7d: PoC Simulators (deferred to Phase 8)

Real-machine integration testing completed on 10.0.0.114 (aarch64 server) and 10.0.0.130 (x86_64 desktop):
- All enrollment, heartbeat, command dispatch, and result submission endpoints validated
- Existing Go nexusd daemon backward-compatible (polls succeed against updated Mothership)
- Phase 7d formal PoC simulators deferred; protocol proven end-to-end via integration tests + real machines

---

## Remaining TODO

Cross-cutting future work items consolidated from all phases.

### Sandbox Enhancements

| Task | Origin | Notes |
|------|--------|-------|
| Container warm pool | Phase 1b | Reduce startup latency (ref: OpenClaw) |
| VM warm pool (pre-boot VMs) | Phase 3 | Reduce VM startup latency |
| Container/facility prune (dual criteria) | Cross | 24h idle OR 7d max age (ref: OpenClaw) |
| Seatbelt/sandbox-exec profiles (macOS) | Phase 5 | Defense-in-depth, not blocking |
| Secret injection (stdin/tmpfs) | Cross | Decision D10 design done, implementation deferred |

### Firecracker Extensions

| Task | Notes |
|------|-------|
| VirtioFS facility mount (rw/rwd modes) | Reference: Gap #18, Decision D15 |
| In-VM defense in depth (bwrap/seccomp inside Firecracker) | Reference: Gap #20, Decision D14 |
| In-VM agent daemon (static-linked Go binary) | Reference: Gap #23, replace command-block approach |
| VM heartbeat + auto-recovery | Reference: Gap #22 |
| Jailer integration (per-VM cgroup + chroot) | Enhanced resource isolation |

### Production Operations

| Task | Notes |
|------|-------|
| Directive checkpoint/resume | Reference: Gap #5 |
| Nexus self-update & rollback | |
| Artifact signing & SBOM | macOS binary signing done; SBOM generation not yet |
| Git tree snapshots | Reference: OpenCode/Codex. Evaluate vs HEAD-based |
| SSH gateway for interactive facility | Reference: Claude.app |

### Phase 8: Device Clients & Agent Integration (planned)

| Task | Phase | Notes |
|------|-------|-------|
| Go Nexus Command support (WebSocket client + command handler) | 8a | Depends on Phase 7 protocol stability |
| iOS/Android native App | 8b | Enrollment, WebSocket, camera/location/audio |
| Push Notification real integration (APNs/FCM) | 8c | Depends on mobile App |
| Bridge SDK + Home Assistant Custom Component | 8d | Python SDK |
| Agent integration (device_command / list_devices tools) | 8e | Depends on Phase 7 API stability |
| Device management Web UI | 8f | QR enrollment, device/entity list, status monitoring |

### Future (Post-Phase 8)

| Task | Notes |
|------|-------|
| Agent-to-agent handoff for multi-territory workflows | Reference: OpenAI Agents SDK |
| MCP-style tool abstraction for AgentCore | Reference: OpenManus |
| Extension/plugin architecture for sandbox drivers | Reference: Pi Mono |
| IPC filesystem for sandbox CLI | Reference: NanoClaw |
| Semantic memory integration with AgentCore | Reference: Memoh |
| Read-only network mode (GET-only proxy) | Reference: Codex. Complex to enforce reliably |
