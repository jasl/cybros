package firecracker

import (
	"encoding/json"
	"strings"
	"testing"
)

// ===================================================================
// Security Boundary Tests — Layer 1: Pure Unit Tests (no KVM needed)
//
// These tests verify the security properties of the Firecracker driver
// at the code/configuration generation level. They run on any OS in CI.
//
// Security properties tested:
//   S1. Drive isolation: rootfs/cmd read-only, only workspace is writable
//   S2. No host env leak: wrapper script does not inherit host environment
//   S3. Shell injection prevention: env keys validated, values quoted
//   S4. Network isolation: only vsock-based proxy, no TAP/bridge
//   S5. Boot args integrity: init=/sbin/nexus-init, no console escape
//   S6. VM config immutability: no extra drives, no network interfaces
//   S7. Cwd path traversal: cannot escape /workspace
//   S8. Exit code spoofing: NEXUS_EXIT_CODE regex is strict
//   S9. Config validation: invalid driver settings rejected
// ===================================================================

// --- S1: Drive Isolation ---

func TestSecurity_RootfsIsReadOnly(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	for _, d := range cfg.Drives {
		if d.DriveID == "rootfs" && !d.IsReadOnly {
			t.Fatal("SECURITY: rootfs drive must be read-only")
		}
	}
}

func TestSecurity_CmdDriveIsReadOnly(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	for _, d := range cfg.Drives {
		if d.DriveID == "cmd" && !d.IsReadOnly {
			t.Fatal("SECURITY: cmd drive must be read-only")
		}
	}
}

func TestSecurity_WorkspaceDriveIsWritable(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	for _, d := range cfg.Drives {
		if d.DriveID == "workspace" && d.IsReadOnly {
			t.Fatal("workspace drive should be writable for the task")
		}
	}
}

func TestSecurity_ExactlyThreeDrives(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	if len(cfg.Drives) != 3 {
		t.Fatalf("SECURITY: expected exactly 3 drives (rootfs, cmd, workspace), got %d", len(cfg.Drives))
	}
}

func TestSecurity_OnlyOneRootDevice(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	rootCount := 0
	for _, d := range cfg.Drives {
		if d.IsRootDevice {
			rootCount++
		}
	}
	if rootCount != 1 {
		t.Fatalf("SECURITY: expected exactly 1 root device, got %d", rootCount)
	}
}

// --- S2: No Host Env Leak ---

func TestSecurity_WrapperNoHostEnvInheritance(t *testing.T) {
	script, err := GenerateWrapper(WrapperConfig{
		UserCommand: "env",
	})
	if err != nil {
		t.Fatal(err)
	}

	// Should NOT have env -i re-exec (unlike bwrap wrapper), because the
	// guest VM already starts with a clean env via nexus-init.
	// But it MUST explicitly set PATH, HOME to known safe values.
	if !strings.Contains(script, "HOME='/workspace'") {
		t.Error("SECURITY: wrapper must set HOME to /workspace")
	}
	if !strings.Contains(script, "PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'") {
		t.Error("SECURITY: wrapper must set a known-safe PATH")
	}
}

func TestSecurity_WrapperSetsProxyEnv(t *testing.T) {
	script, err := GenerateWrapper(WrapperConfig{
		UserCommand: "curl example.com",
	})
	if err != nil {
		t.Fatal(err)
	}

	// All four proxy env vars must be set for comprehensive coverage.
	for _, envVar := range []string{"HTTP_PROXY=", "HTTPS_PROXY=", "http_proxy=", "https_proxy="} {
		if !strings.Contains(script, envVar) {
			t.Errorf("SECURITY: wrapper must set %s for network isolation", envVar)
		}
	}
}

// --- S3: Shell Injection Prevention ---

func TestSecurity_EnvKeyInjection_Semicolon(t *testing.T) {
	_, err := GenerateWrapper(WrapperConfig{
		UserCommand: "echo test",
		Env:         map[string]string{"FOO;rm -rf /": "val"},
	})
	if err == nil {
		t.Fatal("SECURITY: semicolon in env key must be rejected")
	}
}

func TestSecurity_EnvKeyInjection_Backtick(t *testing.T) {
	_, err := GenerateWrapper(WrapperConfig{
		UserCommand: "echo test",
		Env:         map[string]string{"FOO`id`": "val"},
	})
	if err == nil {
		t.Fatal("SECURITY: backtick in env key must be rejected")
	}
}

func TestSecurity_EnvKeyInjection_Dollar(t *testing.T) {
	_, err := GenerateWrapper(WrapperConfig{
		UserCommand: "echo test",
		Env:         map[string]string{"FOO$(id)": "val"},
	})
	if err == nil {
		t.Fatal("SECURITY: $() in env key must be rejected")
	}
}

func TestSecurity_EnvKeyInjection_Newline(t *testing.T) {
	_, err := GenerateWrapper(WrapperConfig{
		UserCommand: "echo test",
		Env:         map[string]string{"FOO\nBAR": "val"},
	})
	if err == nil {
		t.Fatal("SECURITY: newline in env key must be rejected")
	}
}

func TestSecurity_EnvValueInjection_Quoted(t *testing.T) {
	script, err := GenerateWrapper(WrapperConfig{
		UserCommand: "echo test",
		Env:         map[string]string{"FOO": "$(whoami)"},
	})
	if err != nil {
		t.Fatal(err)
	}

	// Value must be single-quoted to prevent shell expansion.
	if !strings.Contains(script, "export FOO='$(whoami)'") {
		t.Errorf("SECURITY: env value must be single-quoted to prevent injection.\nGot:\n%s", script)
	}
}

func TestSecurity_EnvValueInjection_SingleQuoteEscape(t *testing.T) {
	script, err := GenerateWrapper(WrapperConfig{
		UserCommand: "echo test",
		Env:         map[string]string{"FOO": "a'b"},
	})
	if err != nil {
		t.Fatal(err)
	}

	// Must escape single quotes within single-quoted strings.
	if strings.Contains(script, "export FOO='a'b'") {
		t.Error("SECURITY: unescaped single quote in env value allows injection")
	}
}

func TestSecurity_GitCloneEnvInjection(t *testing.T) {
	tests := []struct {
		name string
		env  string
	}{
		{"no equals", "INVALID"},
		{"semicolon in key", "FOO;rm=val"},
		{"space in key", "FOO BAR=val"},
		{"backtick in key", "FOO`id`=val"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := GenerateWrapper(WrapperConfig{
				UserCommand:  "make",
				RepoURL:      "https://github.com/foo/bar.git",
				GitCloneArgs: []string{"git", "clone", "https://github.com/foo/bar.git"},
				GitCloneEnv:  []string{tt.env},
			})
			if err == nil {
				t.Errorf("SECURITY: git clone env %q must be rejected", tt.env)
			}
		})
	}
}

func TestSecurity_UserCommandQuoted(t *testing.T) {
	script, err := GenerateWrapper(WrapperConfig{
		UserCommand: "echo '$(id)'",
	})
	if err != nil {
		t.Fatal(err)
	}

	// The command must be passed via shellQuote to -c, not interpolated.
	if strings.Contains(script, "-c echo") {
		t.Error("SECURITY: user command must be quoted, not directly interpolated")
	}
	if !strings.Contains(script, "/bin/sh -c '") {
		t.Error("SECURITY: user command must be passed via -c with quoting")
	}
}

// --- S4: Network Isolation ---

func TestSecurity_VMConfigNoNetworkInterfaces(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
		VsockUDSPath: "/tmp/vsock.sock",
	})

	// Marshal and check there are no network interfaces.
	data, err := MarshalVMConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// Verify no "network-interfaces" key in the JSON.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	if _, exists := raw["network-interfaces"]; exists {
		t.Fatal("SECURITY: VM config must not contain network-interfaces (use vsock only)")
	}
}

func TestSecurity_VsockOnly_NoTAP(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
		VsockUDSPath: "/tmp/vsock.sock",
	})

	data, _ := MarshalVMConfig(cfg)
	jsonStr := string(data)

	// Must not contain any TAP device references.
	for _, bad := range []string{"tap", "host_dev_name", "iface_id"} {
		if strings.Contains(strings.ToLower(jsonStr), bad) {
			t.Errorf("SECURITY: VM config must not reference TAP devices, found %q", bad)
		}
	}

	// Must have vsock.
	if cfg.Vsock == nil {
		t.Fatal("SECURITY: vsock must be configured for network isolation")
	}
}

func TestSecurity_VsockGuestCID(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
		VsockUDSPath: "/tmp/vsock.sock",
	})

	// Guest CID must be 3 (2 is reserved for host).
	if cfg.Vsock.GuestCID != 3 {
		t.Errorf("SECURITY: guest CID must be 3, got %d", cfg.Vsock.GuestCID)
	}
}

// --- S5: Boot Args Integrity ---

func TestSecurity_BootArgsHasNexusInit(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	if !strings.Contains(cfg.BootSource.BootArgs, "init=/sbin/nexus-init") {
		t.Fatal("SECURITY: boot args must specify init=/sbin/nexus-init")
	}
}

func TestSecurity_BootArgsPanicOnError(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	if !strings.Contains(cfg.BootSource.BootArgs, "panic=1") {
		t.Error("SECURITY: boot args should include panic=1 to reboot on kernel panic")
	}
}

func TestSecurity_BootArgsNoPCI(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	// pci=off reduces attack surface.
	if !strings.Contains(cfg.BootSource.BootArgs, "pci=off") {
		t.Error("SECURITY: boot args should include pci=off to reduce attack surface")
	}
}

func TestSecurity_BootArgsForceReboot(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	if !strings.Contains(cfg.BootSource.BootArgs, "reboot=k") {
		t.Error("SECURITY: boot args should include reboot=k for clean VM shutdown")
	}
}

func TestSecurity_BootArgsNoRW(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	// Must NOT include "rw" — rootfs should remain read-only.
	parts := strings.Fields(cfg.BootSource.BootArgs)
	for _, p := range parts {
		if p == "rw" {
			t.Fatal("SECURITY: boot args must NOT include 'rw' (rootfs must be read-only)")
		}
	}
}

func TestSecurity_BootArgsNoShell(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
	})

	// Must NOT redirect init to an interactive shell.
	for _, bad := range []string{"init=/bin/sh", "init=/bin/bash", "single", "rescue", "emergency"} {
		if strings.Contains(cfg.BootSource.BootArgs, bad) {
			t.Errorf("SECURITY: boot args must NOT contain %q (security bypass)", bad)
		}
	}
}

// --- S6: VM Config Immutability ---

func TestSecurity_VMConfigNoSMT(t *testing.T) {
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        2,
		MemSizeMiB:   512,
	})

	// SMT=false protects against speculative execution side channels.
	if cfg.MachineConfig.SMT {
		t.Error("SECURITY: SMT should be disabled to mitigate speculative execution attacks")
	}
}

func TestSecurity_VMConfigJSONStability(t *testing.T) {
	// Ensure the config JSON doesn't contain unexpected top-level keys.
	cfg := BuildVMConfig(VMConfigInput{
		KernelPath:   "/vmlinux",
		RootfsPath:   "/rootfs.ext4",
		CmdImagePath: "/cmd.ext4",
		WsImagePath:  "/ws.ext4",
		VCPUs:        1,
		MemSizeMiB:   256,
		VsockUDSPath: "/tmp/vsock.sock",
	})

	data, err := MarshalVMConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}

	allowedKeys := map[string]bool{
		"boot-source":    true,
		"drives":         true,
		"machine-config": true,
		"vsock":          true,
	}

	for key := range raw {
		if !allowedKeys[key] {
			t.Errorf("SECURITY: unexpected VM config key %q (may introduce attack surface)", key)
		}
	}
}

// --- S7: Cwd Path Traversal ---

func TestSecurity_CwdPathTraversal(t *testing.T) {
	traversals := []string{
		"../../etc/passwd",
		"../../../",
		"subdir/../../..",
	}

	for _, cwd := range traversals {
		_, err := resolveCwd(cwd)
		if err == nil {
			t.Errorf("SECURITY: cwd %q should be rejected as workspace escape, but was accepted", cwd)
		}
	}
}

func TestSecurity_CwdAbsolutePathOutsideWorkspace(t *testing.T) {
	// Absolute paths outside /workspace must be rejected.
	outsidePaths := []string{
		"/etc/passwd",
		"/tmp",
		"/root",
		"/",
	}

	for _, cwd := range outsidePaths {
		_, err := resolveCwd(cwd)
		if err == nil {
			t.Errorf("SECURITY: absolute cwd %q should be rejected as workspace escape, but was accepted", cwd)
		}
	}
}

func TestSecurity_CwdValidPaths(t *testing.T) {
	// Valid paths inside /workspace must be accepted.
	validPaths := []string{
		"",
		"/workspace",
		"/workspace/subdir",
		"subdir",
		"subdir/nested",
	}

	for _, cwd := range validPaths {
		resolved, err := resolveCwd(cwd)
		if err != nil {
			t.Errorf("cwd %q should be valid, got error: %v", cwd, err)
			continue
		}
		if !strings.HasPrefix(resolved, guestWorkspace) {
			t.Errorf("cwd %q resolved to %q, not under workspace", cwd, resolved)
		}
	}
}

// --- S8: Exit Code Spoofing ---

func TestSecurity_ExitCodeCapture_NonceAntiSpoofing(t *testing.T) {
	// The nonce-based marker prevents guest commands from spoofing exit codes.
	// The guest doesn't know the nonce, so it can only spoof the generic
	// NEXUS_EXIT_CODE= marker (which we no longer match).
	nonce := "a1b2c3d4e5f6g7h8"
	marker := "NEXUS_EXIT_" + nonce + "="

	cap := newExitCodeCapture(marker)

	// Guest command tries to spoof exit code 0 using the old marker.
	cap.Write([]byte("NEXUS_EXIT_CODE=0\n"))
	// Guest command tries a random nonce (wrong).
	cap.Write([]byte("NEXUS_EXIT_wrongnonce=0\n"))
	// The real marker from run.sh (with correct nonce).
	cap.Write([]byte("NEXUS_EXIT_" + nonce + "=42\n"))

	cap.Flush()
	code := cap.ExitCode()
	if code != 42 {
		t.Errorf("SECURITY: exit code capture should return 42 from nonce-tagged line, got %d", code)
	}
}

func TestSecurity_ExitCodeCapture_NoMatch(t *testing.T) {
	cap := newExitCodeCapture("NEXUS_EXIT_unique123=")

	// Only spoofed lines, no real marker.
	cap.Write([]byte("NEXUS_EXIT_CODE=0\n"))
	cap.Write([]byte("some other output\n"))

	cap.Flush()
	code := cap.ExitCode()
	if code != -1 {
		t.Errorf("SECURITY: exit code should be -1 when no nonce match, got %d", code)
	}
}

func TestSecurity_ExitCodeCapture_LastOccurrence(t *testing.T) {
	marker := "NEXUS_EXIT_test123="
	cap := newExitCodeCapture(marker)

	// Multiple occurrences: should keep only the last.
	cap.Write([]byte(marker + "0\n"))
	cap.Write([]byte(marker + "42\n"))

	cap.Flush()
	code := cap.ExitCode()
	if code != 42 {
		t.Errorf("SECURITY: exit code capture should return last occurrence (42), got %d", code)
	}
}

func TestSecurity_ExitCodeCapture_ChunkBoundary(t *testing.T) {
	marker := "NEXUS_EXIT_chunk="
	cap := newExitCodeCapture(marker)

	// Marker split across two Write calls.
	cap.Write([]byte("NEXUS_EXIT_ch"))
	cap.Write([]byte("unk=99\n"))

	cap.Flush()
	code := cap.ExitCode()
	if code != 99 {
		t.Errorf("SECURITY: exit code should handle chunk boundaries, got %d", code)
	}
}

// --- S8b: ExitCodeCapture partial buffer bound ---

func TestSecurity_ExitCodeCapture_PartialBufferBound(t *testing.T) {
	marker := "NEXUS_EXIT_test="
	cap := newExitCodeCapture(marker)

	// Write a huge line without newline (exceeds 4096 partial bound).
	big := strings.Repeat("A", 5000) + marker + "77"
	cap.Write([]byte(big))
	// Flush should still find the marker in the truncated partial.
	cap.Flush()
	code := cap.ExitCode()
	if code != 77 {
		t.Errorf("partial buffer bound should preserve marker tail, got code %d", code)
	}
}

func TestSecurity_ExitCodeCapture_PartialBufferOverflow(t *testing.T) {
	marker := "NEXUS_EXIT_test="
	cap := newExitCodeCapture(marker)

	// Put marker at the BEGINNING of a long line (gets truncated away).
	big := marker + "55" + strings.Repeat("B", 5000)
	cap.Write([]byte(big))
	cap.Flush()
	code := cap.ExitCode()
	// The marker was at the start and gets truncated — should not match.
	if code != -1 {
		t.Errorf("expected -1 when marker is truncated by partial overflow, got %d", code)
	}
}

// --- S9: Config Validation ---

func TestSecurity_DefaultsAreSecure(t *testing.T) {
	// Verify the default boot args haven't been weakened.
	if !strings.Contains(defaultBootArgs, "init=/sbin/nexus-init") {
		t.Fatal("SECURITY: default boot args must specify nexus-init")
	}
	if !strings.Contains(defaultBootArgs, "panic=1") {
		t.Fatal("SECURITY: default boot args must include panic=1")
	}
	if !strings.Contains(defaultBootArgs, "pci=off") {
		t.Fatal("SECURITY: default boot args must include pci=off")
	}
}

// --- Regression: ensure wrapper does NOT start socat ---

func TestSecurity_WrapperDoesNotStartSocat(t *testing.T) {
	script, err := GenerateWrapper(WrapperConfig{
		UserCommand: "echo test",
	})
	if err != nil {
		t.Fatal(err)
	}

	// The firecracker wrapper must NOT start socat — that's nexus-init's job.
	// If socat were in the wrapper, a malicious command image could replace it.
	if strings.Contains(script, "socat") {
		t.Error("SECURITY: firecracker wrapper must NOT start socat (nexus-init handles it)")
	}
}

// --- Regression: minimal exec env ---

func TestSecurity_MinimalExecEnv(t *testing.T) {
	env := minimalExecEnv()

	envMap := make(map[string]string)
	for _, e := range env {
		k, v, ok := strings.Cut(e, "=")
		if !ok {
			t.Errorf("invalid env entry: %q", e)
			continue
		}
		envMap[k] = v
	}

	// Must have PATH.
	if _, ok := envMap["PATH"]; !ok {
		t.Error("SECURITY: minimal env must include PATH")
	}

	// Must NOT include sensitive variables.
	for _, banned := range []string{"AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "SSH_AUTH_SOCK"} {
		if _, ok := envMap[banned]; ok {
			t.Errorf("SECURITY: minimal env must NOT include %s", banned)
		}
	}

	// Should be very small (4 entries).
	if len(env) > 10 {
		t.Errorf("SECURITY: minimal env has %d entries, expected <= 10 (minimize attack surface)", len(env))
	}
}
