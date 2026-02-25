package bwrap

import (
	"strings"
	"testing"
)

func TestGenerateWrapper_Basic(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand: "echo hello",
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatalf("GenerateWrapper: %v", err)
	}

	// Should start with shebang
	if !strings.HasPrefix(script, "#!/bin/sh\n") {
		t.Error("missing shebang")
	}

	// Should clean env via env -i (Phase 1: prevent host env leak)
	if !strings.Contains(script, "/usr/bin/env -i") {
		t.Errorf("missing env -i re-exec in:\n%s", script)
	}
	if !strings.Contains(script, "PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'") {
		t.Errorf("missing PATH in clean env re-exec in:\n%s", script)
	}

	// Should start socat
	if !strings.Contains(script, "socat TCP-LISTEN:9080") {
		t.Error("missing socat start")
	}
	if !strings.Contains(script, "UNIX-CONNECT:/run/egress-proxy.sock") {
		t.Error("missing socat UDS connection")
	}

	// Should set proxy env
	if !strings.Contains(script, "HTTP_PROXY=") {
		t.Error("missing HTTP_PROXY")
	}
	if !strings.Contains(script, "http://127.0.0.1:9080") {
		t.Error("wrong proxy URL")
	}

	// Should set sandbox env
	if !strings.Contains(script, "NO_COLOR=1") {
		t.Error("missing NO_COLOR")
	}
	if !strings.Contains(script, "CI=true") {
		t.Error("missing CI")
	}

	// Should run user command
	if !strings.Contains(script, "/bin/sh -c 'echo hello'") {
		t.Errorf("missing user command execution in:\n%s", script)
	}

	// Should capture exit code
	if !strings.Contains(script, "EXIT_CODE=$?") {
		t.Error("missing exit code capture")
	}

	// Should have cleanup trap
	if !strings.Contains(script, "trap cleanup EXIT") {
		t.Error("missing cleanup trap")
	}
}

func TestGenerateWrapper_Cwd(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand: "pwd",
		Cwd:         "/workspace/subdir",
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(script, "cd '/workspace/subdir'") {
		t.Errorf("missing cd to cwd in:\n%s", script)
	}
}

func TestGenerateWrapper_WithGitClone(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand:  "make test",
		RepoURL:      "https://github.com/foo/bar.git",
		GitCloneArgs: []string{"git", "clone", "--depth", "1", "--", "https://github.com/foo/bar.git", "."},
		GitCloneEnv:  []string{"GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=true"},
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// FIX C4: GitCloneEnv values are now properly quoted
	if !strings.Contains(script, "GIT_TERMINAL_PROMPT='0'") {
		t.Errorf("missing git env var in:\n%s", script)
	}
	if !strings.Contains(script, "'git' 'clone'") {
		t.Error("missing git clone command")
	}
	if !strings.Contains(script, "'https://github.com/foo/bar.git'") {
		t.Error("missing repo URL in clone args")
	}
}

func TestGenerateWrapper_CustomSocat(t *testing.T) {
	cfg := WrapperConfig{
		SocatPath:   "/usr/bin/socat",
		ProxyPort:   8888,
		UserCommand: "ls",
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(script, "/usr/bin/socat TCP-LISTEN:8888") {
		t.Error("custom socat path/port not used")
	}
	if !strings.Contains(script, "http://127.0.0.1:8888") {
		t.Error("proxy URL should use custom port")
	}
}

func TestGenerateWrapper_CustomShell(t *testing.T) {
	cfg := WrapperConfig{
		Shell:       "/bin/bash",
		UserCommand: "echo test",
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(script, "/bin/bash -c") {
		t.Error("custom shell not used")
	}
}

func TestGenerateWrapper_ExtraEnv(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand: "env",
		Env:         map[string]string{"FOO": "bar"},
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// FIX C2: values are now single-quoted via shellQuote
	if !strings.Contains(script, "export FOO='bar'") {
		t.Errorf("extra env var not set correctly, got:\n%s", script)
	}
}

// FIX C2: test that invalid env keys are rejected
func TestGenerateWrapper_InvalidEnvKey(t *testing.T) {
	tests := []struct {
		name string
		key  string
	}{
		{"injection via semicolon", "FOO;rm -rf /"},
		{"injection via backtick", "FOO`id`"},
		{"starts with number", "1FOO"},
		{"contains space", "FOO BAR"},
		{"contains equals", "FOO=BAR"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := WrapperConfig{
				UserCommand: "env",
				Env:         map[string]string{tt.key: "val"},
			}
			_, err := GenerateWrapper(cfg)
			if err == nil {
				t.Error("expected error for invalid env key")
			}
		})
	}
}

// FIX C4: test that GitCloneEnv values are properly quoted
func TestGenerateWrapper_GitCloneEnvQuoted(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand:  "make test",
		RepoURL:      "https://github.com/foo/bar.git",
		GitCloneArgs: []string{"git", "clone", "--", "https://github.com/foo/bar.git", "."},
		GitCloneEnv:  []string{"GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=true"},
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// Values should be single-quoted
	if !strings.Contains(script, "export GIT_TERMINAL_PROMPT='0'") {
		t.Errorf("GitCloneEnv not properly quoted:\n%s", script)
	}
}

// FIX C4: test that invalid GitCloneEnv entries are rejected
func TestGenerateWrapper_InvalidGitCloneEnv(t *testing.T) {
	tests := []struct {
		name string
		env  string
	}{
		{"no equals sign", "INVALID"},
		{"injection in key", "FOO;rm=val"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := WrapperConfig{
				UserCommand:  "echo test",
				RepoURL:      "https://example.com/repo.git",
				GitCloneArgs: []string{"git", "clone", "https://example.com/repo.git"},
				GitCloneEnv:  []string{tt.env},
			}
			_, err := GenerateWrapper(cfg)
			if err == nil {
				t.Error("expected error for invalid GitCloneEnv")
			}
		})
	}
}

// FIX C7: Verify that the generated wrapper prevents host env leakage.
// The wrapper re-execs under `env -i` with only a minimal set of env vars,
// ensuring tokens/API keys from the host environment are never inherited.
func TestGenerateWrapper_EnvIsolation(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand: "env",
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// 1. Must use env -i to strip host environment
	if !strings.Contains(script, "exec /usr/bin/env -i") {
		t.Error("wrapper must re-exec under env -i to prevent host env leakage")
	}

	// 2. Must have the NEXUS_WRAPPER_CLEAN_ENV guard to avoid infinite re-exec loop
	if !strings.Contains(script, "NEXUS_WRAPPER_CLEAN_ENV") {
		t.Error("wrapper must check NEXUS_WRAPPER_CLEAN_ENV to guard env -i re-exec")
	}

	// 3. Only a known-safe set of env vars should be passed through env -i
	allowedEnvVars := []string{"PATH=", "HOME=", "LANG=", "LC_ALL="}
	for _, v := range allowedEnvVars {
		if !strings.Contains(script, v) {
			t.Errorf("wrapper env -i block must include %s", v)
		}
	}

	// 4. Must NOT contain any reference to $HOME, $USER, or other host-specific vars
	// in the env -i re-exec block (before the guard check)
	lines := strings.Split(script, "\n")
	inEnvBlock := false
	for _, line := range lines {
		if strings.Contains(line, "exec /usr/bin/env -i") {
			inEnvBlock = true
		}
		if inEnvBlock && strings.Contains(line, "/bin/sh \"$0\"") {
			break
		}
		if inEnvBlock {
			// No variable expansion from host env in the env -i block
			if strings.Contains(line, "$USER") || strings.Contains(line, "$SHELL") {
				t.Errorf("env -i block must not reference host variables: %s", line)
			}
		}
	}
}

func TestGenerateWrapper_EmptyCommand(t *testing.T) {
	_, err := GenerateWrapper(WrapperConfig{})
	if err == nil {
		t.Fatal("expected error for empty command")
	}
}

func TestGenerateWrapper_CommandWithSingleQuotes(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand: "echo 'hello world'",
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// Should properly escape single quotes
	if !strings.Contains(script, `-c 'echo '`) {
		t.Errorf("single quotes not properly escaped:\n%s", script)
	}
}

func TestShellQuote(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"hello", "'hello'"},
		{"hello world", "'hello world'"},
		{"it's", "'it'\"'\"'s'"},
		{"", "''"},
	}

	for _, tt := range tests {
		got := shellQuote(tt.input)
		if got != tt.want {
			t.Errorf("shellQuote(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}
