//go:build darwin

package cli

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"cybros.ai/nexus/config"
)

func platformChecks(_ *config.Config) []DoctorCheck {
	var checks []DoctorCheck

	checks = append(checks, checkOsascript())
	checks = append(checks, checkShortcuts())

	// Linux-only tools: report as skipped on macOS.
	checks = append(checks,
		DoctorCheck{Name: "bwrap", Status: "skip", Detail: "Linux only (skipped on macOS)"},
		DoctorCheck{Name: "socat", Status: "skip", Detail: "Linux only (skipped on macOS)"},
		DoctorCheck{Name: "podman", Status: "skip", Detail: "Linux only (skipped on macOS)"},
		DoctorCheck{Name: "rootfs", Status: "skip", Detail: "Linux only (skipped on macOS)"},
	)

	return checks
}

// checkOsascript verifies the AppleScript/JXA engine is available.
func checkOsascript() DoctorCheck {
	path, err := exec.LookPath("osascript")
	if err != nil {
		return DoctorCheck{Name: "osascript", Status: "fail", Detail: "not found in PATH"}
	}

	// Verify osascript can execute a trivial AppleScript.
	// Use a 5-second timeout to prevent doctor from blocking.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "osascript", "-e", `return "ok"`).Output()
	if err != nil {
		return DoctorCheck{Name: "osascript", Status: "warn", Detail: fmt.Sprintf("found at %s but execution failed", path)}
	}

	result := strings.TrimSpace(string(out))
	if result != "ok" {
		return DoctorCheck{Name: "osascript", Status: "warn", Detail: fmt.Sprintf("unexpected output: %q", result)}
	}

	return DoctorCheck{Name: "osascript", Status: "ok", Detail: path}
}

// checkShortcuts verifies the Shortcuts CLI is available (macOS 12+).
func checkShortcuts() DoctorCheck {
	path, err := exec.LookPath("shortcuts")
	if err != nil {
		return DoctorCheck{Name: "shortcuts", Status: "warn", Detail: "not found (requires macOS 12+)"}
	}

	return DoctorCheck{Name: "shortcuts", Status: "ok", Detail: path}
}
