//go:build darwin

package darwinautomation

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// checkTCCPermissions probes macOS TCC (Transparency, Consent, and Control)
// permission status for keys relevant to desktop automation. Results are
// informational only — they do NOT gate driver health.
//
// Checked permissions:
//   - osascript: AppleScript/JXA engine availability
//   - shortcuts: Shortcuts CLI (macOS 12+)
func checkTCCPermissions() map[string]string {
	result := map[string]string{}

	// Check osascript availability (AppleScript/JXA engine).
	if path, err := exec.LookPath("osascript"); err == nil {
		result["tcc_osascript"] = "available (" + path + ")"
	} else {
		result["tcc_osascript"] = "not_found"
	}

	// Check shortcuts CLI availability (macOS 12 Monterey+).
	if _, err := exec.LookPath("shortcuts"); err == nil {
		// Try listing shortcuts to verify access (non-destructive).
		// Use a 5-second timeout to prevent HealthCheck from blocking.
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		out, err := exec.CommandContext(ctx, "shortcuts", "list").Output()
		if err != nil {
			result["tcc_shortcuts"] = "binary_found_but_list_failed"
		} else {
			lines := strings.Split(strings.TrimSpace(string(out)), "\n")
			count := len(lines)
			if count == 1 && lines[0] == "" {
				count = 0
			}
			result["tcc_shortcuts"] = fmt.Sprintf("available (%d shortcuts)", count)
		}
	} else {
		result["tcc_shortcuts"] = "not_found"
	}

	return result
}
