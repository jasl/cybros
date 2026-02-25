//go:build !linux && !darwin

package cli

import "cybros.ai/nexus/config"

func platformChecks(_ *config.Config) []DoctorCheck {
	return []DoctorCheck{
		{Name: "bwrap", Status: "warn", Detail: "Linux only (skipped on this platform)"},
		{Name: "socat", Status: "warn", Detail: "Linux only (skipped on this platform)"},
		{Name: "podman", Status: "warn", Detail: "Linux only (skipped on this platform)"},
		{Name: "rootfs", Status: "skip", Detail: "Linux only (skipped on this platform)"},
	}
}
