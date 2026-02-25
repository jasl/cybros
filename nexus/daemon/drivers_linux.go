//go:build linux

package daemon

import (
	"context"
	"fmt"
	"runtime"
	"time"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/rootfs"
	"cybros.ai/nexus/sandbox"
	bwrapdriver "cybros.ai/nexus/sandbox/bwrap"
	containerdriver "cybros.ai/nexus/sandbox/container"
	firecrackerdriver "cybros.ai/nexus/sandbox/firecracker"
	hostdriver "cybros.ai/nexus/sandbox/host"
)

// newDriverFactory creates a factory with all Linux-supported drivers.
func newDriverFactory(cfg config.Config) (*sandbox.DriverFactory, error) {
	bwrapCfg := cfg.Bwrap

	if bwrapCfg.RootfsPath == "" && cfg.Rootfs.Auto {
		var src config.RootfsArchSourceConfig
		switch runtime.GOARCH {
		case "amd64":
			src = cfg.Rootfs.AMD64
		case "arm64":
			src = cfg.Rootfs.ARM64
		default:
			return nil, fmt.Errorf("rootfs.auto is not supported on GOARCH=%s", runtime.GOARCH)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
		defer cancel()

		rootfsPath, err := rootfs.EnsureUbuntu2404(ctx, cfg.Rootfs.CacheDir, runtime.GOARCH, rootfs.Source{
			URL:    src.URL,
			SHA256: src.SHA256,
		})
		if err != nil {
			return nil, err
		}
		bwrapCfg.RootfsPath = rootfsPath
	}

	drivers := []sandbox.Driver{
		hostdriver.New(),
		bwrapdriver.New(bwrapCfg),
		containerdriver.New(cfg.Container),
	}

	if cfg.UntrustedDriver == "firecracker" {
		drivers = append(drivers, firecrackerdriver.New(cfg.Firecracker))
	}

	factory := sandbox.NewFactory(drivers...)

	if cfg.UntrustedDriver == "firecracker" {
		factory.SetUntrustedDriver("firecracker")
	}

	return factory, nil
}
