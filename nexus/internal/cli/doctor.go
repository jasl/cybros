package cli

import (
	"fmt"
	"os/exec"
	"strings"

	"cybros.ai/nexus/config"
)

// DoctorCheck represents a single dependency check.
type DoctorCheck struct {
	Name   string
	Status string // "ok", "warn", "fail"
	Detail string
}

// RunDoctor runs all platform checks and returns results.
func RunDoctor(cfg *config.Config) []DoctorCheck {
	var checks []DoctorCheck

	// Portable checks
	checks = append(checks, checkGit())

	// Platform-specific checks (implemented in doctor_linux.go / doctor_other.go)
	checks = append(checks, platformChecks(cfg)...)

	return checks
}

// PrintDoctorResults prints the results in a human-readable format.
func PrintDoctorResults(checks []DoctorCheck) {
	fmt.Println("nexusd doctor")
	fmt.Println(strings.Repeat("─", 50))

	allOK := true
	for _, c := range checks {
		icon := "✓"
		if c.Status == "skip" {
			icon = "─"
		} else if c.Status == "warn" {
			icon = "⚠"
			allOK = false
		} else if c.Status == "fail" {
			icon = "✗"
			allOK = false
		}
		fmt.Printf("  %s %-25s %s\n", icon, c.Name, c.Detail)
	}

	fmt.Println(strings.Repeat("─", 50))
	if allOK {
		fmt.Println("  All checks passed.")
	} else {
		fmt.Println("  Some checks failed. See details above.")
	}
}

func checkGit() DoctorCheck {
	path, err := exec.LookPath("git")
	if err != nil {
		return DoctorCheck{Name: "git", Status: "fail", Detail: "not found in PATH"}
	}

	out, err := exec.Command("git", "--version").Output()
	if err != nil {
		return DoctorCheck{Name: "git", Status: "warn", Detail: fmt.Sprintf("found at %s but --version failed", path)}
	}

	ver := strings.TrimSpace(string(out))
	return DoctorCheck{Name: "git", Status: "ok", Detail: ver}
}
