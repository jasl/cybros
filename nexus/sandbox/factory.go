package sandbox

import (
	"context"
	"fmt"
	"sync"
)

// DriverFactory creates sandbox drivers by profile name.
type DriverFactory struct {
	drivers         map[string]Driver
	untrustedDriver string // override for "untrusted" profile; empty = default "bwrap"
}

// NewFactory creates a DriverFactory with the given drivers.
// Each driver is registered under its Name().
func NewFactory(drivers ...Driver) *DriverFactory {
	m := make(map[string]Driver, len(drivers))
	for _, d := range drivers {
		m[d.Name()] = d
	}
	return &DriverFactory{drivers: m}
}

// SetUntrustedDriver overrides which driver serves the "untrusted" profile.
func (f *DriverFactory) SetUntrustedDriver(name string) {
	f.untrustedDriver = name
}

// Get returns the driver for the given sandbox profile.
// Profile-to-driver mapping:
//
//	"host"      → "host" driver
//	"untrusted" → "bwrap" or "firecracker" driver (configurable via SetUntrustedDriver)
//	"trusted"   → "container" driver (falls back to "host" if container not registered)
func (f *DriverFactory) Get(profile string) (Driver, error) {
	driverName := f.profileToDriver(profile)
	d, ok := f.drivers[driverName]
	if !ok {
		// Fallback: "trusted" falls back to "host" when no container driver available
		if profile == "trusted" {
			if host, exists := f.drivers["host"]; exists {
				return host, nil
			}
		}
		return nil, fmt.Errorf("no driver registered for profile %q (driver %q)", profile, driverName)
	}
	return d, nil
}

// SupportedProfiles returns profiles that this factory can serve.
func (f *DriverFactory) SupportedProfiles() []string {
	var profiles []string
	if _, ok := f.drivers["host"]; ok {
		profiles = append(profiles, "host")
	}
	// "untrusted" is supported if the configured driver is registered
	untrustedName := f.profileToDriver("untrusted")
	if _, ok := f.drivers[untrustedName]; ok {
		profiles = append(profiles, "untrusted")
	}
	// "trusted" is supported if we have container OR host (fallback)
	if _, ok := f.drivers["container"]; ok {
		profiles = append(profiles, "trusted")
	} else if _, ok := f.drivers["host"]; ok {
		profiles = append(profiles, "trusted")
	}
	// "darwin-automation" is supported if the driver is registered
	if _, ok := f.drivers["darwin-automation"]; ok {
		profiles = append(profiles, "darwin-automation")
	}
	return profiles
}

// HealthCheckAll runs HealthCheck on every registered driver concurrently
// and returns results keyed by driver name.
func (f *DriverFactory) HealthCheckAll(ctx context.Context) map[string]HealthResult {
	results := make(map[string]HealthResult, len(f.drivers))
	var mu sync.Mutex
	var wg sync.WaitGroup
	for name, drv := range f.drivers {
		wg.Add(1)
		go func(name string, drv Driver) {
			defer wg.Done()
			r := drv.HealthCheck(ctx)
			mu.Lock()
			results[name] = r
			mu.Unlock()
		}(name, drv)
	}
	wg.Wait()
	return results
}

// UntrustedDriverName returns the driver name used for the "untrusted" profile.
// Included in heartbeat payloads so Mothership can map profiles to the correct driver.
func (f *DriverFactory) UntrustedDriverName() string {
	return f.profileToDriver("untrusted")
}

// profileToDriver maps a sandbox profile name to the driver name.
func (f *DriverFactory) profileToDriver(profile string) string {
	switch profile {
	case "untrusted":
		if f.untrustedDriver != "" {
			return f.untrustedDriver
		}
		return "bwrap"
	case "trusted":
		return "container"
	case "host":
		return "host"
	default:
		return profile
	}
}
