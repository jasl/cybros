// Package container implements a rootless container (Podman/Docker) sandbox driver.
// The cmdbuilder file has no build tag so it can be unit-tested on any platform;
// only container.go is Linux-only.
package container

import (
	"fmt"
	"path"
	"regexp"
	"strings"
)

// validEnvKeyRe matches safe POSIX environment variable names.
var validEnvKeyRe = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

// CmdConfig holds the inputs needed to construct a podman/docker run invocation.
type CmdConfig struct {
	// Runtime is the container runtime binary (e.g., "podman" or "docker").
	Runtime string

	// Image is the container image (e.g., "ubuntu:24.04").
	Image string

	// FacilityPath is the host-side facility directory, mounted at /workspace.
	FacilityPath string

	// Command is the user command to run.
	Command string

	// Shell is the shell to use (default: /bin/sh).
	Shell string

	// Cwd is the working directory inside the container (after prepare).
	// Default: /workspace. Must stay under /workspace.
	Cwd string

	// Env is additional environment variables.
	Env map[string]string

	// ProxyMode controls proxy injection: "env" or "none".
	ProxyMode string

	// ProxyURL is the proxy URL (e.g., "http://host.containers.internal:9080").
	// Only used when ProxyMode is "env".
	ProxyURL string

	// RepoURL triggers a git clone before the user command.
	RepoURL string

	// GitCloneArgs are the full git clone arguments.
	GitCloneArgs []string
	// GitCloneEnv are the env vars for git clone.
	GitCloneEnv []string
}

// BuildArgs constructs the runtime run argument slice.
func BuildArgs(cfg CmdConfig) ([]string, error) {
	if cfg.Runtime == "" {
		return nil, fmt.Errorf("runtime is required")
	}
	if cfg.Image == "" {
		return nil, fmt.Errorf("image is required")
	}
	if cfg.FacilityPath == "" {
		return nil, fmt.Errorf("facility path is required")
	}
	if cfg.Command == "" {
		return nil, fmt.Errorf("command is required")
	}

	shell := cfg.Shell
	if shell == "" {
		shell = "/bin/sh"
	}

	resolvedCwd, err := resolveCwd(cfg.Cwd)
	if err != nil {
		return nil, err
	}

	args := []string{cfg.Runtime, "run", "--rm"}

	// Network: use host networking so the container can reach the proxy
	args = append(args, "--network=host")

	// FIX H9: Security hardening
	args = append(args, "--cap-drop=ALL")
	args = append(args, "--security-opt=no-new-privileges")

	// Volume mount: facility → /workspace
	args = append(args, "--volume", cfg.FacilityPath+":/workspace:Z")

	// Working directory
	args = append(args, "--workdir", "/workspace")

	// Standard sandbox env vars
	args = append(args, "--env", "NO_COLOR=1")
	args = append(args, "--env", "TERM=dumb")
	args = append(args, "--env", "CI=true")

	// Proxy env injection (soft constraint)
	if cfg.ProxyMode == "env" && cfg.ProxyURL != "" {
		args = append(args, "--env", "HTTP_PROXY="+cfg.ProxyURL)
		args = append(args, "--env", "HTTPS_PROXY="+cfg.ProxyURL)
		args = append(args, "--env", "http_proxy="+cfg.ProxyURL)
		args = append(args, "--env", "https_proxy="+cfg.ProxyURL)
	}

	// Additional env vars (FIX C3: validate key to prevent injection)
	for k, v := range cfg.Env {
		if !validEnvKeyRe.MatchString(k) {
			return nil, fmt.Errorf("invalid env key: %q", k)
		}
		args = append(args, "--env", k+"="+v)
	}

	// Image
	args = append(args, cfg.Image)

	// Build the inner command
	innerCmd := buildInnerCommand(cfg, shell, resolvedCwd)
	args = append(args, shell, "-c", innerCmd)

	return args, nil
}

// buildInnerCommand assembles the script run inside the container.
func buildInnerCommand(cfg CmdConfig, shell string, cwd string) string {
	var parts []string

	// Git clone if repo URL is provided
	if cfg.RepoURL != "" && len(cfg.GitCloneArgs) > 0 {
		var b strings.Builder
		b.WriteString("if [ -z \"$(find /workspace -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)\" ]; then ")

		// Set git env vars (FIX C4: validate key and quote value)
		for _, e := range cfg.GitCloneEnv {
			k, v, ok := strings.Cut(e, "=")
			if !ok || !validEnvKeyRe.MatchString(k) {
				continue // skip invalid entries; validated upstream
			}
			b.WriteString("export ")
			b.WriteString(k)
			b.WriteString("=")
			b.WriteString(shellQuote(v))
			b.WriteString("; ")
		}

		// Git clone command (only when workspace is empty)
		var quotedArgs []string
		for _, a := range cfg.GitCloneArgs {
			quotedArgs = append(quotedArgs, shellQuote(a))
		}
		b.WriteString(strings.Join(quotedArgs, " "))
		b.WriteString("; ")
		b.WriteString("else echo '[prepare] workspace not empty; skipping clone' >&2; fi")

		parts = append(parts, b.String())
	}

	if cwd != "" && cwd != "/workspace" {
		parts = append(parts, "cd "+shellQuote(cwd))
	}

	// User command
	parts = append(parts, cfg.Command)

	return strings.Join(parts, " && ")
}

// shellQuote wraps a string in single quotes, escaping internal single quotes.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

func resolveCwd(requested string) (string, error) {
	cwd := requested
	if cwd == "" || cwd == "." {
		cwd = "/workspace"
	}
	if !strings.HasPrefix(cwd, "/") {
		cwd = "/workspace/" + cwd
	}

	cwd = path.Clean(cwd)
	if cwd != "/workspace" && !strings.HasPrefix(cwd, "/workspace/") {
		return "", fmt.Errorf("cwd %q escapes workspace", requested)
	}
	return cwd, nil
}
