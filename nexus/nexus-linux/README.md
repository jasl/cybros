# nexus-linux

Linux Nexus daemon (Go) skeleton.

## Current State (MVP)
- Host driver only (executes commands directly on the host) — for integration testing with the Mothership control plane.
- Untrusted microVM / egress hardening / privileged helper are skeleton placeholders (future iterations).

## Build

```bash
make build-linux
```

Output binaries go to `dist/`.

## Run

```bash
./dist/nexusd-linux-amd64 --config ./nexus-linux/config.yaml
```

## systemd

See `packaging/systemd/nexusd.service` and `packaging/install.sh` (skeleton).
