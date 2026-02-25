package sandbox

import (
	"fmt"
	"net/url"
	"strings"
)

// IsAllowedRepoScheme validates that a repo URL uses a safe git transport.
// This prevents git ext:: protocol injection which can execute arbitrary commands.
func IsAllowedRepoScheme(raw string) bool {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return false
	}
	if strings.ContainsAny(raw, " \t\r\n") || strings.HasPrefix(raw, "-") {
		return false
	}
	if strings.HasPrefix(strings.ToLower(raw), "ext::") {
		return false
	}

	if !strings.Contains(raw, "://") {
		return isAllowedRepoSCPStyle(raw)
	}

	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" {
		return false
	}
	switch strings.ToLower(u.Scheme) {
	case "https", "http", "ssh", "git":
		return true
	default:
		return false
	}
}

// isAllowedRepoSCPStyle validates "user@host:path" remotes.
func isAllowedRepoSCPStyle(raw string) bool {
	at := strings.IndexByte(raw, '@')
	if at <= 0 {
		return false
	}
	colonRel := strings.IndexByte(raw[at+1:], ':')
	if colonRel <= 0 {
		return false
	}
	colon := at + 1 + colonRel
	if colon >= len(raw)-1 {
		return false
	}

	user := raw[:at]
	host := raw[at+1 : colon]
	path := raw[colon+1:]

	if user == "" || host == "" || path == "" {
		return false
	}
	if strings.HasPrefix(user, "-") || strings.HasPrefix(host, "-") || strings.HasPrefix(path, "-") {
		return false
	}
	if strings.ContainsAny(host, "/\\") {
		return false
	}
	if host != "localhost" && !strings.Contains(host, ".") {
		return false
	}
	return true
}

// PrepareGitCloneArgs returns the git clone arguments and environment variables
// for safely cloning a repository into the current directory.
func PrepareGitCloneArgs(repoURL string) (args []string, env []string, err error) {
	if !IsAllowedRepoScheme(repoURL) {
		return nil, nil, fmt.Errorf("repo_url uses disallowed scheme (only https, http, ssh, git, or scp-like ssh are allowed)")
	}

	args = []string{"git", "clone", "--depth", "1", "--", repoURL, "."}
	env = []string{
		"GIT_TERMINAL_PROMPT=0",
		"GIT_ASKPASS=true",
		"GIT_PROTOCOL_FROM_USER=0",
		"GIT_ALLOW_PROTOCOL=http:https:ssh:git",
	}
	return args, env, nil
}

// RedactRepoURL removes credentials from a repo URL for logging.
func RedactRepoURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err == nil && parsed.User != nil {
		parsed.User = nil
		return parsed.String()
	}
	if strings.Contains(raw, "://") {
		return raw
	}
	if at := strings.IndexByte(raw, '@'); at > 0 {
		return "REDACTED" + raw[at:]
	}
	return raw
}
