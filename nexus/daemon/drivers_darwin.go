//go:build darwin

package daemon

import (
	"cybros.ai/nexus/config"
	"cybros.ai/nexus/sandbox"
	darwinautomation "cybros.ai/nexus/sandbox/darwinautomation"
	hostdriver "cybros.ai/nexus/sandbox/host"
)

// newDriverFactory creates a factory with host and darwin-automation drivers on macOS.
func newDriverFactory(cfg config.Config) (*sandbox.DriverFactory, error) {
	return sandbox.NewFactory(
		hostdriver.New(),
		darwinautomation.New(),
	), nil
}
