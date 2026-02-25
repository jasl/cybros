package firecracker

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

	if !strings.HasPrefix(script, "#!/bin/sh\n") {
		t.Error("missing shebang")
	}

	// Should NOT contain socat (started by nexus-init, not wrapper)
	if strings.Contains(script, "socat") {
		t.Error("wrapper should not start socat (nexus-init handles it)")
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

func TestGenerateWrapper_DefaultCwdSkipsCd(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand: "pwd",
		Cwd:         "/workspace",
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	if strings.Contains(script, "cd '") {
		t.Error("should not cd when cwd is /workspace")
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

	if !strings.Contains(script, "export FOO='bar'") {
		t.Errorf("extra env var not set correctly, got:\n%s", script)
	}
}

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

	if !strings.Contains(script, `-c 'echo '`) {
		t.Errorf("single quotes not properly escaped:\n%s", script)
	}
}

func TestGenerateWrapper_ExitMarker(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand: "echo test",
		ExitMarker:  "NEXUS_EXIT_abc123=",
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// Marker must appear in the script to echo the nonce-tagged exit code.
	if !strings.Contains(script, "NEXUS_EXIT_abc123=") {
		t.Errorf("exit marker not found in script:\n%s", script)
	}
	// Must reference EXIT_CODE variable.
	if !strings.Contains(script, "echo 'NEXUS_EXIT_abc123='\"${EXIT_CODE}\"") {
		t.Errorf("exit marker not correctly formatted in script:\n%s", script)
	}
}

func TestGenerateWrapper_NoExitMarker(t *testing.T) {
	cfg := WrapperConfig{
		UserCommand: "echo test",
		// ExitMarker intentionally empty.
	}

	script, err := GenerateWrapper(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// Should not contain any NEXUS_EXIT_ echo line.
	if strings.Contains(script, "NEXUS_EXIT_") {
		t.Errorf("no exit marker should be emitted when ExitMarker is empty:\n%s", script)
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
