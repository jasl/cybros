package bwrap

import (
	"fmt"
	"regexp"
	"strings"
)

// validEnvKeyRe matches safe POSIX environment variable names.
var validEnvKeyRe = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

// WrapperConfig holds the inputs for generating the wrapper shell script
// that runs inside the bubblewrap sandbox.
type WrapperConfig struct {
	// SocatPath is the path to socat inside the sandbox.
	SocatPath string

	// ProxyPort is the local TCP port for the socat bridge. Default: 9080.
	ProxyPort int

	// Cwd is the working directory inside the sandbox after prepare. Default: /workspace.
	// Must be an absolute path under /workspace (validated by the caller).
	Cwd string

	// UserCommand is the command to run inside the sandbox.
	UserCommand string

	// Shell is the shell to use for running the user command. Default: /bin/sh.
	Shell string

	// RepoURL triggers a git clone before running the user command.
	// Empty means no git clone.
	RepoURL string

	// GitCloneArgs are the args for git clone (from sandbox.PrepareGitCloneArgs).
	GitCloneArgs []string
	// GitCloneEnv are the env vars for git clone.
	GitCloneEnv []string

	// Env is additional environment variables to export (key=value pairs).
	Env map[string]string
}

// GenerateWrapper produces a shell script that:
//  1. Starts socat to bridge the proxy UDS to a local TCP port.
//  2. Exports HTTP_PROXY/HTTPS_PROXY pointing at the socat bridge.
//  3. Optionally runs git clone for facility preparation.
//  4. Runs the user command.
//  5. Captures the exit code and cleans up.
func GenerateWrapper(cfg WrapperConfig) (string, error) {
	if cfg.UserCommand == "" {
		return "", fmt.Errorf("user command is required")
	}

	socatPath := cfg.SocatPath
	if socatPath == "" {
		socatPath = "socat"
	}

	proxyPort := cfg.ProxyPort
	if proxyPort == 0 {
		proxyPort = sandboxProxyPort
	}

	shell := cfg.Shell
	if shell == "" {
		shell = "/bin/sh"
	}

	var b strings.Builder

	b.WriteString("#!/bin/sh\n")

	// Clean environment: do not inherit host env (may contain secrets).
	// We re-exec the wrapper once under env -i to ensure a minimal, predictable env.
	b.WriteString("if [ \"${NEXUS_WRAPPER_CLEAN_ENV:-}\" != \"1\" ]; then\n")
	b.WriteString("  exec /usr/bin/env -i \\\n")
	b.WriteString("    NEXUS_WRAPPER_CLEAN_ENV=1 \\\n")
	b.WriteString("    PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \\\n")
	b.WriteString("    HOME='/workspace' \\\n")
	b.WriteString("    LANG='C' \\\n")
	b.WriteString("    LC_ALL='C' \\\n")
	b.WriteString("    /bin/sh \"$0\"\n")
	b.WriteString("fi\n\n")

	b.WriteString("set -e\n\n")

	// Start socat bridge: UDS → TCP
	fmt.Fprintf(&b,
		"%s TCP-LISTEN:%d,reuseaddr,fork UNIX-CONNECT:%s &\n",
		socatPath, proxyPort, sandboxProxySock,
	)
	b.WriteString("SOCAT_PID=$!\n")

	// Trap for cleanup
	b.WriteString("cleanup() { kill \"$SOCAT_PID\" 2>/dev/null || true; }\n")
	b.WriteString("trap cleanup EXIT\n\n")

	// Wait briefly for socat to start listening
	b.WriteString("sleep 0.1\n\n")

	// Set proxy env vars
	proxyURL := fmt.Sprintf("http://127.0.0.1:%d", proxyPort)
	fmt.Fprintf(&b, "export HTTP_PROXY=%s\n", shellQuote(proxyURL))
	fmt.Fprintf(&b, "export HTTPS_PROXY=%s\n", shellQuote(proxyURL))
	fmt.Fprintf(&b, "export http_proxy=%s\n", shellQuote(proxyURL))
	fmt.Fprintf(&b, "export https_proxy=%s\n", shellQuote(proxyURL))

	// Standard sandbox env vars
	b.WriteString("export NO_COLOR=1\n")
	b.WriteString("export TERM=dumb\n")
	b.WriteString("export CI=true\n")

	// Additional env vars (FIX C2: validate key to prevent shell injection)
	for k, v := range cfg.Env {
		if !validEnvKeyRe.MatchString(k) {
			return "", fmt.Errorf("invalid env key: %q", k)
		}
		fmt.Fprintf(&b, "export %s=%s\n", k, shellQuote(v))
	}
	b.WriteString("\n")

	// Optional git clone
	if cfg.RepoURL != "" && len(cfg.GitCloneArgs) > 0 {
		b.WriteString("if [ -z \"$(find /workspace -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)\" ]; then\n")

		// Set git env vars (FIX C4: validate key and quote value)
		for _, e := range cfg.GitCloneEnv {
			k, v, ok := strings.Cut(e, "=")
			if !ok || !validEnvKeyRe.MatchString(k) {
				return "", fmt.Errorf("invalid git clone env: %q", e)
			}
			fmt.Fprintf(&b, "  export %s=%s\n", k, shellQuote(v))
		}

		// Run git clone
		var quotedArgs []string
		for _, a := range cfg.GitCloneArgs {
			quotedArgs = append(quotedArgs, shellQuote(a))
		}
		fmt.Fprintf(&b, "  %s\n", strings.Join(quotedArgs, " "))
		b.WriteString("else\n")
		b.WriteString("  echo '[prepare] workspace not empty; skipping clone' >&2\n")
		b.WriteString("fi\n\n")
	}

	if cfg.Cwd != "" && cfg.Cwd != sandboxWorkspace {
		fmt.Fprintf(&b, "cd %s\n\n", shellQuote(cfg.Cwd))
	}

	// Run user command (allow non-zero exit)
	b.WriteString("set +e\n")
	fmt.Fprintf(&b, "%s -c %s\n", shell, shellQuote(cfg.UserCommand))
	b.WriteString("EXIT_CODE=$?\n")
	b.WriteString("set -e\n\n")

	// Exit with the user command's exit code
	b.WriteString("exit $EXIT_CODE\n")

	return b.String(), nil
}

// shellQuote wraps a string in single quotes, escaping internal single quotes.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
