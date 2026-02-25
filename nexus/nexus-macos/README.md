# nexus-macos

macOS Nexus daemon (Go) skeleton.

Product strategy: only supports `darwin-automation` (Apple Silicon, targeting macOS 26+). No container/isolation execution.

## Build

```bash
make build-macos
```

## Run

```bash
./dist/nexusd-macos-arm64 --config ./nexus-macos/config.yaml
```

## Important: Permissions (TCC)

If you want Nexus to automate apps (AppleEvents/Accessibility/Screen Recording, etc.),
the user must grant authorization in System Settings. Enterprise environments typically
need MDM to deploy a PPPC (Privacy Preferences Policy Control) profile.
