package bwrap

import (
	"strings"
	"testing"
)

func TestBuildArgs_DefaultHostRoot(t *testing.T) {
	cfg := CmdConfig{
		BwrapPath:         "/usr/bin/bwrap",
		FacilityPath:      "/data/facilities/abc",
		ProxySocketPath:   "/tmp/proxy.sock",
		WrapperScriptPath: "/tmp/wrapper.sh",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatalf("BuildArgs: %v", err)
	}

	joined := strings.Join(args, " ")

	// Check binary
	if args[0] != "/usr/bin/bwrap" {
		t.Errorf("first arg = %q, want bwrap path", args[0])
	}

	// Default mode: tmpfs root with host directories
	assertContainsSequence(t, args, "--tmpfs", "/")
	assertContainsSequence(t, args, "--ro-bind", "/usr", "/usr")
	assertContainsSequence(t, args, "--symlink", "usr/bin", "/bin")
	assertContainsSequence(t, args, "--symlink", "usr/sbin", "/sbin")
	assertContainsSequence(t, args, "--symlink", "usr/lib", "/lib")
	assertContainsSequence(t, args, "--ro-bind", "/etc", "/etc")

	// No --ro-bind / / in default mode
	assertNotContainsSequence(t, args, "--ro-bind", "/", "/")

	// Virtual filesystems
	assertContainsSequence(t, args, "--proc", "/proc")
	assertContainsSequence(t, args, "--dev", "/dev")
	assertContainsSequence(t, args, "--tmpfs", "/tmp")
	assertContainsSequence(t, args, "--tmpfs", "/run")

	// Workspace
	assertContainsSequence(t, args, "--bind", "/data/facilities/abc", "/workspace")

	// Namespace isolation
	assertContains(t, args, "--unshare-net")
	assertContains(t, args, "--unshare-pid")
	assertContains(t, args, "--unshare-uts")
	assertContains(t, args, "--unshare-ipc")

	// Security
	assertContains(t, args, "--new-session")
	assertContains(t, args, "--die-with-parent")
	assertContainsSequence(t, args, "--cap-drop", "ALL")

	// Root remounted read-only after all mounts
	assertContainsSequence(t, args, "--remount-ro", "/")

	// Proxy socket mount
	assertContainsSequence(t, args, "--ro-bind", "/tmp/proxy.sock", "/run/egress-proxy.sock")

	// Wrapper script mount
	assertContainsSequence(t, args, "--ro-bind", "/tmp/wrapper.sh", "/run/wrapper.sh")

	// Default cwd
	assertContainsSequence(t, args, "--chdir", "/workspace")

	// Executor
	if !strings.HasSuffix(joined, "-- /bin/sh /run/wrapper.sh") {
		t.Errorf("args should end with wrapper execution, got: %s", joined)
	}
}

func TestBuildArgs_CustomRootfs(t *testing.T) {
	cfg := CmdConfig{
		BwrapPath:         "bwrap",
		RootfsPath:        "/opt/rootfs/ubuntu",
		FacilityPath:      "/data/fac",
		ProxySocketPath:   "/tmp/p.sock",
		WrapperScriptPath: "/tmp/w.sh",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// Custom rootfs uses --ro-bind for the entire root
	assertContainsSequence(t, args, "--ro-bind", "/opt/rootfs/ubuntu", "/")

	// Should NOT have the merged-usr symlinks
	assertNotContains(t, args, "--symlink")
}

func TestBuildArgs_HostHasLib64(t *testing.T) {
	cfg := CmdConfig{
		BwrapPath:         "bwrap",
		FacilityPath:      "/data/fac",
		ProxySocketPath:   "/tmp/p.sock",
		WrapperScriptPath: "/tmp/w.sh",
		HostHasLib64:      true,
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	assertContainsSequence(t, args, "--symlink", "usr/lib64", "/lib64")
}

func TestBuildArgs_NoLib64ByDefault(t *testing.T) {
	cfg := CmdConfig{
		BwrapPath:         "bwrap",
		FacilityPath:      "/data/fac",
		ProxySocketPath:   "/tmp/p.sock",
		WrapperScriptPath: "/tmp/w.sh",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// Default (aarch64): no lib64 symlink
	for i, a := range args {
		if a == "--symlink" && i+2 < len(args) && args[i+2] == "/lib64" {
			t.Error("should not have /lib64 symlink when HostHasLib64 is false")
		}
	}
}

func TestBuildArgs_CustomCwd(t *testing.T) {
	cfg := CmdConfig{
		BwrapPath:         "bwrap",
		FacilityPath:      "/data/fac",
		ProxySocketPath:   "/tmp/p.sock",
		WrapperScriptPath: "/tmp/w.sh",
		Cwd:               "subdir",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	assertContainsSequence(t, args, "--chdir", "/workspace")
}

func TestBuildArgs_AbsoluteCwd(t *testing.T) {
	cfg := CmdConfig{
		BwrapPath:         "bwrap",
		FacilityPath:      "/data/fac",
		ProxySocketPath:   "/tmp/p.sock",
		WrapperScriptPath: "/tmp/w.sh",
		Cwd:               "/workspace/deep/path",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	assertContainsSequence(t, args, "--chdir", "/workspace")
}

func TestBuildArgs_Errors(t *testing.T) {
	tests := []struct {
		name string
		cfg  CmdConfig
	}{
		{"missing bwrap path", CmdConfig{FacilityPath: "/f", ProxySocketPath: "/p", WrapperScriptPath: "/w"}},
		{"missing facility", CmdConfig{BwrapPath: "b", ProxySocketPath: "/p", WrapperScriptPath: "/w"}},
		{"missing proxy socket", CmdConfig{BwrapPath: "b", FacilityPath: "/f", WrapperScriptPath: "/w"}},
		{"missing wrapper", CmdConfig{BwrapPath: "b", FacilityPath: "/f", ProxySocketPath: "/p"}},
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

func TestBuildArgs_RemountRoBeforeNamespaceArgs(t *testing.T) {
	cfg := CmdConfig{
		BwrapPath:         "bwrap",
		FacilityPath:      "/data/fac",
		ProxySocketPath:   "/tmp/p.sock",
		WrapperScriptPath: "/tmp/w.sh",
	}

	args, err := BuildArgs(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// Find positions of key elements
	remountIdx := -1
	workspaceIdx := -1
	for i, a := range args {
		if a == "--remount-ro" && i+1 < len(args) && args[i+1] == "/" {
			remountIdx = i
		}
		if a == "--bind" && i+2 < len(args) && args[i+2] == "/workspace" {
			workspaceIdx = i
		}
	}

	if remountIdx < 0 {
		t.Fatal("--remount-ro / not found")
	}
	if workspaceIdx < 0 {
		t.Fatal("--bind ... /workspace not found")
	}

	// remount-ro must come AFTER the workspace bind
	if remountIdx < workspaceIdx {
		t.Error("--remount-ro / should come after workspace bind mount")
	}
}

// FIX H5: test that path traversal in Cwd is rejected
func TestBuildArgs_CwdPathTraversal(t *testing.T) {
	base := CmdConfig{
		BwrapPath:         "bwrap",
		FacilityPath:      "/data/fac",
		ProxySocketPath:   "/tmp/p.sock",
		WrapperScriptPath: "/tmp/w.sh",
	}

	traversalCwds := []string{
		"../../etc",
		"../../../",
		"subdir/../../..",
		"/etc/passwd",
		"/tmp",
	}

	for _, cwd := range traversalCwds {
		cfg := base
		cfg.Cwd = cwd
		_, err := BuildArgs(cfg)
		if err == nil {
			t.Errorf("Cwd=%q should be rejected as path traversal", cwd)
		}
	}

	// These should succeed
	safeCwds := []string{
		"subdir",
		"deep/nested/path",
		"/workspace/subdir",
		"/workspace",
		"",
	}

	for _, cwd := range safeCwds {
		cfg := base
		cfg.Cwd = cwd
		_, err := BuildArgs(cfg)
		if err != nil {
			t.Errorf("Cwd=%q should be accepted, got error: %v", cwd, err)
		}
	}
}

func TestSandboxConstants(t *testing.T) {
	if SandboxWorkspace() != "/workspace" {
		t.Error("workspace constant changed")
	}
	if SandboxProxySock() != "/run/egress-proxy.sock" {
		t.Error("proxy socket constant changed")
	}
	if SandboxProxyPort() != 9080 {
		t.Error("proxy port constant changed")
	}
}

// assertContains checks that the arg appears at least once.
func assertContains(t *testing.T, args []string, want string) {
	t.Helper()
	for _, a := range args {
		if a == want {
			return
		}
	}
	t.Errorf("args missing %q", want)
}

// assertNotContains checks that the arg does NOT appear.
func assertNotContains(t *testing.T, args []string, bad string) {
	t.Helper()
	for _, a := range args {
		if a == bad {
			t.Errorf("args should not contain %q", bad)
			return
		}
	}
}

// assertContainsSequence checks that args contains the given subsequence.
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

// assertNotContainsSequence checks that args does NOT contain the given subsequence.
func assertNotContainsSequence(t *testing.T, args []string, seq ...string) {
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
			t.Errorf("args should not contain sequence %v", seq)
			return
		}
	}
}
