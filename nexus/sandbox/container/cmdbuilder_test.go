package container

import (
	"strings"
	"testing"
)

func TestBuildArgs_Basic(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/facilities/abc",
		Command:      "echo hello",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatalf("BuildArgs: %v", err)
	}

	joined := strings.Join(args, " ")

	// Binary
	if args[0] != "podman" {
		t.Errorf("first arg = %q, want podman", args[0])
	}

	// Must have run --rm
	assertContainsSequence(t, args, "run", "--rm")

	// Network
	assertContains(t, args, "--network=host")

	// Volume
	assertContainsSequence(t, args, "--volume", "/data/facilities/abc:/workspace:Z")

	// Workdir
	assertContainsSequence(t, args, "--workdir", "/workspace")

	// Standard env
	assertContainsSequence(t, args, "--env", "NO_COLOR=1")
	assertContainsSequence(t, args, "--env", "CI=true")

	// Image before command
	if !strings.Contains(joined, "ubuntu:24.04 /bin/sh -c") {
		t.Errorf("missing image + shell pattern in: %s", joined)
	}

	// Inner command
	lastArg := args[len(args)-1]
	if lastArg != "echo hello" {
		t.Errorf("inner command = %q, want %q", lastArg, "echo hello")
	}
}

func TestBuildArgs_WithProxy(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "curl example.com",
		ProxyMode:    "env",
		ProxyURL:     "http://host.containers.internal:9080",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	assertContainsSequence(t, args, "--env", "HTTP_PROXY=http://host.containers.internal:9080")
	assertContainsSequence(t, args, "--env", "HTTPS_PROXY=http://host.containers.internal:9080")
	assertContainsSequence(t, args, "--env", "http_proxy=http://host.containers.internal:9080")
	assertContainsSequence(t, args, "--env", "https_proxy=http://host.containers.internal:9080")
}

func TestBuildArgs_NoProxyWhenModeNone(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "ls",
		ProxyMode:    "none",
		ProxyURL:     "http://should-not-appear:9080",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	joined := strings.Join(args, " ")
	if strings.Contains(joined, "should-not-appear") {
		t.Error("proxy URL should not be injected when mode=none")
	}
}

func TestBuildArgs_WithDocker(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "docker",
		Image:        "node:20",
		FacilityPath: "/data/fac",
		Command:      "npm test",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	if args[0] != "docker" {
		t.Errorf("first arg = %q, want docker", args[0])
	}
}

func TestBuildArgs_WithGitClone(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "make test",
		RepoURL:      "https://github.com/foo/bar.git",
		GitCloneArgs: []string{"git", "clone", "--depth", "1", "--", "https://github.com/foo/bar.git", "."},
		GitCloneEnv:  []string{"GIT_TERMINAL_PROMPT=0"},
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	lastArg := args[len(args)-1]
	// FIX C4: GitCloneEnv values are now properly quoted
	if !strings.Contains(lastArg, "GIT_TERMINAL_PROMPT='0'") {
		t.Errorf("missing quoted git env in inner command: %s", lastArg)
	}
	if !strings.Contains(lastArg, "'git' 'clone'") {
		t.Error("missing git clone in inner command")
	}
	if !strings.Contains(lastArg, "make test") {
		t.Error("missing user command in inner command")
	}
}

func TestBuildArgs_CustomShell(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "echo test",
		Shell:        "/bin/bash",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "/bin/bash -c") {
		t.Error("custom shell not used")
	}
}

func TestBuildArgs_ExtraEnv(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "env",
		Env:          map[string]string{"FOO": "bar"},
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	assertContainsSequence(t, args, "--env", "FOO=bar")
}

func TestBuildArgs_Cwd(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "echo hello",
		Cwd:          "subdir",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	lastArg := args[len(args)-1]
	if !strings.Contains(lastArg, "cd '/workspace/subdir' && echo hello") {
		t.Errorf("inner command = %q, want cd + command", lastArg)
	}
}

func TestBuildArgs_CwdPathTraversalRejected(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "echo hello",
		Cwd:          "../../etc",
	}

	_, err := BuildArgs(cfg)
	if err == nil {
		t.Fatal("expected error")
	}
}

// FIX H9: test security hardening args
func TestBuildArgs_SecurityHardening(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "echo test",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	assertContains(t, args, "--cap-drop=ALL")
	assertContains(t, args, "--security-opt=no-new-privileges")
}

// FIX C3: test that invalid env keys are rejected
func TestBuildArgs_InvalidEnvKey(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "env",
		Env:          map[string]string{"BAD;KEY": "val"},
	}

	_, err := BuildArgs(cfg)
	if err == nil {
		t.Error("expected error for invalid env key")
	}
}

// FIX C4: test that GitCloneEnv values are quoted in inner command
func TestBuildArgs_GitCloneEnvQuoted(t *testing.T) {
	cfg := CmdConfig{
		Runtime:      "podman",
		Image:        "ubuntu:24.04",
		FacilityPath: "/data/fac",
		Command:      "make test",
		RepoURL:      "https://github.com/foo/bar.git",
		GitCloneArgs: []string{"git", "clone", "https://github.com/foo/bar.git"},
		GitCloneEnv:  []string{"GIT_TERMINAL_PROMPT=0"},
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	lastArg := args[len(args)-1]
	// Value should be single-quoted
	if !strings.Contains(lastArg, "GIT_TERMINAL_PROMPT='0'") {
		t.Errorf("GitCloneEnv not properly quoted in inner command: %s", lastArg)
	}
}

func TestBuildArgs_Errors(t *testing.T) {
	tests := []struct {
		name string
		cfg  CmdConfig
	}{
		{"missing runtime", CmdConfig{Image: "i", FacilityPath: "/f", Command: "c"}},
		{"missing image", CmdConfig{Runtime: "r", FacilityPath: "/f", Command: "c"}},
		{"missing facility", CmdConfig{Runtime: "r", Image: "i", Command: "c"}},
		{"missing command", CmdConfig{Runtime: "r", Image: "i", FacilityPath: "/f"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := BuildArgs(tt.cfg)
			if err == nil {
				t.Error("expected error")
			}
		})
	}
}

func assertContains(t *testing.T, args []string, want string) {
	t.Helper()
	for _, a := range args {
		if a == want {
			return
		}
	}
	t.Errorf("args missing %q", want)
}

func assertContainsSequence(t *testing.T, args []string, seq ...string) {
	t.Helper()
	for i := 0; i <= len(args)-len(seq); i++ {
		match := true
		for j, s := range seq {
			if args[i+j] != s {
				match = false
				break
			}
		}
		if match {
			return
		}
	}
	t.Errorf("args missing sequence %v\nfull args: %v", seq, args)
}
