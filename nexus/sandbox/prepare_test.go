package sandbox

import "testing"

func TestIsAllowedRepoScheme(t *testing.T) {
	tests := []struct {
		url     string
		allowed bool
	}{
		// Good URLs
		{"https://github.com/foo/bar.git", true},
		{"http://github.com/foo/bar", true},
		{"ssh://git@github.com/foo/bar.git", true},
		{"git://example.com/repo.git", true},
		{"git@github.com:foo/bar.git", true},

		// Bad URLs
		{"", false},
		{"ext::sh -c 'evil'", false},
		{"-malicious", false},
		{"file:///etc/passwd", false},
		{"ftp://example.com/repo.git", false},
		{"  \t", false},
		{"nohost:path", false},

		// SCP-style edge cases
		{"user@host.com:repo.git", true},
		{"user@localhost:repo.git", true},
		{"@host.com:path", false},
		{"user@:path", false},
		{"user@host:", false},
		{"user@-host.com:path", false},
	}

	for _, tt := range tests {
		got := IsAllowedRepoScheme(tt.url)
		if got != tt.allowed {
			t.Errorf("IsAllowedRepoScheme(%q) = %v, want %v", tt.url, got, tt.allowed)
		}
	}
}

func TestPrepareGitCloneArgs(t *testing.T) {
	args, env, err := PrepareGitCloneArgs("https://github.com/foo/bar.git")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Check args
	if len(args) != 7 {
		t.Fatalf("expected 7 args, got %d: %v", len(args), args)
	}
	if args[0] != "git" || args[1] != "clone" {
		t.Errorf("unexpected args: %v", args)
	}

	// Check env
	if len(env) != 4 {
		t.Fatalf("expected 4 env vars, got %d", len(env))
	}

	// Disallowed scheme
	_, _, err = PrepareGitCloneArgs("ext::evil")
	if err == nil {
		t.Fatal("expected error for ext:: scheme")
	}
}

func TestRedactRepoURL(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"https://github.com/foo/bar.git", "https://github.com/foo/bar.git"},
		{"https://user:pass@github.com/foo/bar.git", "https://github.com/foo/bar.git"},
		{"git@github.com:foo/bar.git", "REDACTED@github.com:foo/bar.git"},
		{"plain-text", "plain-text"},
	}

	for _, tt := range tests {
		got := RedactRepoURL(tt.input)
		if got != tt.expected {
			t.Errorf("RedactRepoURL(%q) = %q, want %q", tt.input, got, tt.expected)
		}
	}
}
