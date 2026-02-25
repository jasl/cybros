//go:build !linux && !darwin

package daemon

import (
	"cybros.ai/nexus/config"
	"cybros.ai/nexus/sandbox"
	hostdriver "cybros.ai/nexus/sandbox/host"
)

// newDriverFactory creates a factory with only the host driver on non-Linux/non-darwin platforms.
func newDriverFactory(cfg config.Config) (*sandbox.DriverFactory, error) {
	return sandbox.NewFactory(hostdriver.New()), nil
}
