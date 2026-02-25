package firecracker

import (
	"fmt"
	"regexp"
	"strings"
)

// validEnvKeyRe matches safe POSIX environment variable names.
var validEnvKeyRe = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

const (
	guestWorkspace = "/workspace"
	guestProxyPort = 9080
)

// WrapperConfig holds the inputs for generating the wrapper shell script
// that runs inside the Firecracker guest VM (on /dev/vdb as /mnt/cmd/run.sh).
//
// Unlike the bwrap wrapper, this script does NOT start socat — the guest's
// nexus-init already runs socat to bridge vsock CID=2:9080 → TCP:9080.
type WrapperConfig struct {
	// Cwd is the working directory inside the guest. Default: /workspace.
	Cwd string

	// UserCommand is the command to run.
	UserCommand string

	// Shell is the shell to use. Default: /bin/sh.
	Shell string

	// RepoURL triggers a git clone before running the user command.
	RepoURL string

	// GitCloneArgs are the args for git clone.
	GitCloneArgs []string
	// GitCloneEnv are the env vars for git clone.
	GitCloneEnv []string

	// Env is additional environment variables to export (key=value pairs).
	Env map[string]string

	// ExitMarker is the per-execution nonce-tagged exit code marker prefix.
	// e.g., "NEXUS_EXIT_a1b2c3d4=". The wrapper echoes this with the exit code
	// so the host can identify it without risk of spoofing by guest commands.
	ExitMarker string
}

// GenerateWrapper produces a shell script for the Firecracker guest:
//  1. Exports HTTP_PROXY/HTTPS_PROXY pointing at the socat bridge (started by nexus-init).
//  2. Exports user environment variables.
//  3. Optionally runs git clone for facility preparation.
//  4. Runs the user command.
//  5. Exits with the command's exit code.
func GenerateWrapper(cfg WrapperConfig) (string, error) {
	if cfg.UserCommand == "" {
		return "", fmt.Errorf("user command is required")
	}

	shell := cfg.Shell
	if shell == "" {
		shell = "/bin/sh"
	}

	var b strings.Builder

	b.WriteString("#!/bin/sh\n")
	b.WriteString("set -e\n\n")

	// Proxy env vars — socat is already running (started by nexus-init).
	proxyURL := fmt.Sprintf("http://127.0.0.1:%d", guestProxyPort)
	fmt.Fprintf(&b, "export HTTP_PROXY=%s\n", shellQuote(proxyURL))
	fmt.Fprintf(&b, "export HTTPS_PROXY=%s\n", shellQuote(proxyURL))
	fmt.Fprintf(&b, "export http_proxy=%s\n", shellQuote(proxyURL))
	fmt.Fprintf(&b, "export https_proxy=%s\n", shellQuote(proxyURL))

	// Standard sandbox env vars.
	b.WriteString("export NO_COLOR=1\n")
	b.WriteString("export TERM=dumb\n")
	b.WriteString("export CI=true\n")
	b.WriteString("export HOME='/workspace'\n")
	b.WriteString("export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'\n")

	// Additional user env vars (validate keys to prevent shell injection).
	for k, v := range cfg.Env {
		if !validEnvKeyRe.MatchString(k) {
			return "", fmt.Errorf("invalid env key: %q", k)
		}
		fmt.Fprintf(&b, "export %s=%s\n", k, shellQuote(v))
	}
	b.WriteString("\n")

	// Optional git clone.
	if cfg.RepoURL != "" && len(cfg.GitCloneArgs) > 0 {
		b.WriteString("if [ -z \"$(find /workspace -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)\" ]; then\n")

		for _, e := range cfg.GitCloneEnv {
			k, v, ok := strings.Cut(e, "=")
			if !ok || !validEnvKeyRe.MatchString(k) {
				return "", fmt.Errorf("invalid git clone env: %q", e)
			}
			fmt.Fprintf(&b, "  export %s=%s\n", k, shellQuote(v))
		}

		var quotedArgs []string
		for _, a := range cfg.GitCloneArgs {
			quotedArgs = append(quotedArgs, shellQuote(a))
		}
		fmt.Fprintf(&b, "  %s\n", strings.Join(quotedArgs, " "))
		b.WriteString("else\n")
		b.WriteString("  echo '[prepare] workspace not empty; skipping clone' >&2\n")
		b.WriteString("fi\n\n")
	}

	if cfg.Cwd != "" && cfg.Cwd != guestWorkspace {
		fmt.Fprintf(&b, "cd %s\n\n", shellQuote(cfg.Cwd))
	}

	// Run user command (allow non-zero exit).
	b.WriteString("set +e\n")
	fmt.Fprintf(&b, "%s -c %s\n", shell, shellQuote(cfg.UserCommand))
	b.WriteString("EXIT_CODE=$?\n")
	b.WriteString("set -e\n\n")

	// Echo exit code with per-execution nonce marker (anti-spoofing).
	// The host captures this instead of the generic NEXUS_EXIT_CODE from nexus-init.
	if cfg.ExitMarker != "" {
		fmt.Fprintf(&b, "echo '%s'\"${EXIT_CODE}\"\n", cfg.ExitMarker)
	}

	b.WriteString("exit $EXIT_CODE\n")

	return b.String(), nil
}

// shellQuote wraps a string in single quotes, escaping internal single quotes.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
