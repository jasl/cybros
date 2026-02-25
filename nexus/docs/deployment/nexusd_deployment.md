# Nexusd Deployment Guide

Covers prerequisites, building, configuration, and running `nexusd` on Linux and macOS.

---

## Linux Prerequisites

### Required (all profiles)

```bash
sudo apt update
sudo apt install -y git
```

### Untrusted profile (bubblewrap)

```bash
sudo apt install -y bubblewrap socat
```

Kernel requirements:

```bash
# User namespaces (usually enabled by default on Ubuntu 24.04)
cat /proc/sys/kernel/unprivileged_userns_clone   # should be 1
# If 0:
sudo sysctl kernel.unprivileged_userns_clone=1
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/99-userns.conf

# AppArmor restriction (Ubuntu 24.04+, NVIDIA Tegra)
cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns   # should be 0
# If 1:
sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-bwrap-userns.conf
sudo sysctl --system
```

### Trusted profile (container)

```bash
sudo apt install -y podman
```

### Firecracker microVM (optional untrusted driver)

Only needed when using `untrusted_driver: "firecracker"` instead of the default bubblewrap.
See [design doc](../design/08_firecracker.md) for architecture details.

```bash
# KVM access
sudo usermod -aG kvm $USER
# Log out and back in, then verify:
test -r /dev/kvm && echo "KVM accessible"

# Firecracker binary
mkdir -p ~/.cybros/bin
ARCH=$(uname -m)
FC_VER=v1.14.1
curl -sL "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VER}/firecracker-${FC_VER}-${ARCH}.tgz" -o fc.tgz
tar xzf fc.tgz
mv release-${FC_VER}-${ARCH}/firecracker-${FC_VER}-${ARCH} ~/.cybros/bin/firecracker
mv release-${FC_VER}-${ARCH}/jailer-${FC_VER}-${ARCH} ~/.cybros/bin/jailer
chmod +x ~/.cybros/bin/firecracker ~/.cybros/bin/jailer
rm -rf release-${FC_VER}-${ARCH} fc.tgz

# ext4 tools (usually pre-installed on Ubuntu)
sudo apt install -y e2fsprogs fuse2fs fuse3
```

Build VM assets:

```bash
cd /path/to/cybros-nexus
bash tools/build-fc-rootfs.sh
mv firecracker-rootfs-*.ext4 ~/.cybros/rootfs.ext4
mv vmlinux ~/.cybros/vmlinux
```

Or download guest kernel manually:

```bash
ARCH=$(uname -m)
curl -sL "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.14/${ARCH}/vmlinux-5.10.245" \
  -o ~/.cybros/vmlinux
```

---

## macOS Prerequisites

macOS only supports the `darwin-automation` profile (Apple Silicon only, no container/isolation).

Required:
- Xcode Command Line Tools (`xcode-select --install`)
- osascript (built-in)
- Shortcuts CLI (built-in on macOS 12+)

No additional dependencies needed.

---

## Build

```bash
# Linux (amd64 + arm64)
make build-linux

# macOS (arm64 only)
make build-macos
```

Or build from source:

```bash
# Linux
go build -o nexusd ./nexus-linux/cmd/nexusd

# macOS
go build -o nexusd ./nexus-macos/cmd/nexusd
```

---

## Self-Check

Run `nexusd -doctor` to verify all dependencies:

```bash
./nexusd -doctor
```

Example output (Linux, all profiles):
```
nexusd doctor
──────────────────────────────────────────────────
  ✓ git                       git version 2.x.x
  ✓ bwrap                     bubblewrap 0.x.x
  ✓ socat                     socat version 1.x.x.x
  ✓ podman                    podman version 4.x.x
  ✓ user_namespaces           enabled
  ✓ apparmor_userns           unrestricted
  ✓ bwrap_functional          sandbox invocation succeeded
──────────────────────────────────────────────────
  All checks passed.
```

Example output (macOS):
```
nexusd doctor
──────────────────────────────────────────────────
  ✓ git                       git version 2.x.x
  ✓ osascript                 found
  ✓ shortcuts                 found
  ─ bwrap                     not applicable on macOS
  ─ socat                     not applicable on macOS
──────────────────────────────────────────────────
  All checks passed.
```

---

## Enrollment (mTLS)

Register territory and obtain client certificates:

```bash
./nexusd -config config.yaml \
  -enroll-token "<token>" \
  -enroll-with-csr=true \
  -enroll-out-dir ./nexus-credentials
```

This writes `client.pem`, `client-key.pem`, and `ca.pem` to the output directory.

---

## Configuration

See `nexus-linux/config.example.yaml` and `nexus-macos/config.example.yaml` for full examples.

### Minimal Linux config

```yaml
server_url: "https://mothership.example.com"
territory_id: "your-territory-uuid"
name: "nexus-prod-01"
work_dir: "/var/lib/nexusd/facilities"

supported_sandbox_profiles:
  - untrusted
  - trusted
  - host

tls:
  ca_file: "/etc/nexusd/ca.pem"
  client_cert_file: "/etc/nexusd/client.pem"
  client_key_file: "/etc/nexusd/client-key.pem"

rootfs:
  auto: true
  cache_dir: "/var/lib/nexusd/rootfs-cache"

bwrap:
  bwrap_path: "bwrap"
  socat_path: "socat"

container:
  runtime: "podman"
  image: "ubuntu:24.04"

poll:
  long_poll_timeout: "25s"
  retry_backoff: "2s"
  max_directives_to_claim: 1

log:
  max_output_bytes: 2000000
  chunk_bytes: 16384

# Phase 6: observability
observability:
  enabled: true
  listen_addr: ":9090"    # /healthz, /readyz, /metrics

shutdown_timeout: "60s"
```

### Firecracker config additions

```yaml
untrusted_driver: "firecracker"

firecracker:
  firecracker_path: "~/.cybros/bin/firecracker"
  kernel_path: "~/.cybros/vmlinux"
  rootfs_image_path: "~/.cybros/rootfs.ext4"
  vcpus: 2
  mem_size_mib: 512
  workspace_size_mib: 2048
```

### Minimal macOS config

```yaml
server_url: "https://mothership.example.com"
territory_id: "your-territory-uuid"
name: "nexus-macos"
work_dir: "./facilities"

supported_sandbox_profiles:
  - darwin-automation

tls:
  ca_file: "./nexus-credentials/ca.pem"
  client_cert_file: "./nexus-credentials/client.pem"
  client_key_file: "./nexus-credentials/client-key.pem"

poll:
  long_poll_timeout: "25s"
  retry_backoff: "2s"
  max_directives_to_claim: 1

log:
  max_output_bytes: 2000000
  chunk_bytes: 16384
```

---

## Running

```bash
./nexusd -config config.yaml
```

With observability enabled, verify endpoints:

```bash
curl http://localhost:9090/healthz   # 200 "ok"
curl http://localhost:9090/readyz    # 200/503
curl http://localhost:9090/metrics   # Prometheus format
```

### systemd (Linux production)

See `nexus-linux/packaging/systemd/` for service files.

### launchd (macOS)

See `nexus-macos/packaging/launchd/` for plist files.

---

## Sandbox Profiles

| Profile | Driver | Network | Isolation | Platform |
|---------|--------|---------|-----------|----------|
| `untrusted` | bwrap / firecracker | Hard (proxy + namespace) | Full namespace / microVM | Linux |
| `trusted` | container (Podman) | Soft (proxy env) | Container | Linux |
| `host` | host | None | Process only | Linux / macOS |
| `darwin-automation` | darwinautomation | None | Process only | macOS (Apple Silicon) |

### untrusted (bwrap)

- Rootfs: pinned Ubuntu 24.04 (read-only) or host `/` (read-only fallback)
- Workspace: facility dir at `/workspace` (read-write)
- Network: `--unshare-net` (isolated namespace)
- Egress: socat → UDS proxy → HTTP/CONNECT + SOCKS5 (domain-only allowlist)
- PID/UTS/IPC: isolated, `--die-with-parent`, `--new-session`, `--cap-drop ALL`

### untrusted (firecracker)

- 3-drive model: rootfs (read-only), cmd (read-only), workspace (read-write ext4)
- Network: vsock → egress proxy (no TAP/nftables, no root required)
- Full hypervisor isolation (KVM)

### trusted (container)

- Runtime: Podman rootless, `--cap-drop=ALL`, `--security-opt=no-new-privileges`
- Network: `--network=host` + `HTTP_PROXY`/`HTTPS_PROXY` env (soft constraint)
- Workspace: facility dir at `/workspace:Z`

---

## Testing

```bash
# Full test suite
go test ./...

# Integration tests (Linux, requires bwrap + socat + podman)
go test -v -count=1 ./sandbox/bwrap/...
go test -v -count=1 -timeout 120s ./sandbox/container/...

# Firecracker tests (Linux, requires KVM + VM assets)
go test -v -count=1 -timeout 120s ./sandbox/firecracker/...
```

---

## Troubleshooting

### bwrap: Operation not permitted

```bash
# Check user namespaces
cat /proc/sys/kernel/unprivileged_userns_clone
# If 0: sudo sysctl kernel.unprivileged_userns_clone=1

# Check AppArmor restriction (Ubuntu 24.04+, NVIDIA Tegra)
cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns
# If 1: sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
```

### bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted

AppArmor restricting user namespaces — disable restriction:

```bash
sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-bwrap-userns.conf
```

### podman: permission denied

```bash
grep $USER /etc/subuid
grep $USER /etc/subgid
# If missing:
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
podman system migrate
```

### Socket path too long

Unix socket paths limited to 108 characters. Configure shorter path:

```yaml
bwrap:
  proxy_socket_dir: "/tmp/nexus-proxy"
```

### macOS: osascript not found

Ensure Xcode Command Line Tools are installed:

```bash
xcode-select --install
```
