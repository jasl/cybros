package main

import (
	"cybros.ai/nexus/config"
	"cybros.ai/nexus/internal/cli"
)

func main() {
	cli.Run("./nexus-macos/config.yaml", macOSDefaults)
}

func macOSDefaults(cfg *config.Config) {
	if len(cfg.SupportedSandboxProfiles) == 0 {
		cfg.SupportedSandboxProfiles = []string{"darwin-automation"}
	}
}
