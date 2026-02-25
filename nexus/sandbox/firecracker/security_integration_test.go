//go:build integration

package firecracker

// ===================================================================
// Security Boundary Tests — Layer 2: Integration Tests (KVM required)
//
// Run with: go test -tags=integration -v ./sandbox/firecracker/...
//
// These tests boot a real Firecracker microVM and verify isolation properties
// that cannot be checked at the unit test level. They require:
//   - /dev/kvm (read+write access)
//   - firecracker binary in PATH
//   - kernel + rootfs images (set via NEXUS_TEST_KERNEL / NEXUS_TEST_ROOTFS env)
//   - mke2fs (e2fsprogs)
//
// Security properties tested:
//   I1. Filesystem isolation: guest cannot read host /etc/hostname
//   I2. Network isolation: guest has no direct internet (only vsock proxy)
//   I3. Exit code accuracy: guest exit code reaches host correctly
//   I4. Workspace sync: only workspace changes are visible post-run
//   I5. Resource limits: VM respects vcpu/memory constraints
// ===================================================================

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/protocol"
	"cybros.ai/nexus/sandbox"
)

func testKernelPath(t *testing.T) string {
	t.Helper()
	p := os.Getenv("NEXUS_TEST_KERNEL")
	if p == "" {
		t.Skip("NEXUS_TEST_KERNEL not set (path to vmlinux)")
	}
	if _, err := os.Stat(p); err != nil {
		t.Skipf("NEXUS_TEST_KERNEL not found: %v", err)
	}
	return p
}

func testRootfsPath(t *testing.T) string {
	t.Helper()
	p := os.Getenv("NEXUS_TEST_ROOTFS")
	if p == "" {
		t.Skip("NEXUS_TEST_ROOTFS not set (path to rootfs.ext4)")
	}
	if _, err := os.Stat(p); err != nil {
		t.Skipf("NEXUS_TEST_ROOTFS not found: %v", err)
	}
	return p
}

func testKVMAvailable(t *testing.T) {
	t.Helper()
	f, err := os.OpenFile("/dev/kvm", os.O_RDWR, 0)
	if err != nil {
		t.Skipf("/dev/kvm not accessible: %v", err)
	}
	f.Close()
}

// stubLogSink captures output from the VM.
type stubLogSink struct {
	stdout strings.Builder
	stderr strings.Builder
}

func (s *stubLogSink) Consume(_ context.Context, stream string, r io.Reader) error {
	var b strings.Builder
	if _, err := io.Copy(&b, r); err != nil {
		return err
	}
	switch stream {
	case "stdout":
		s.stdout.WriteString(b.String())
	case "stderr":
		s.stderr.WriteString(b.String())
	}
	return nil
}

func newTestDriver(t *testing.T) *Driver {
	t.Helper()
	testKVMAvailable(t)

	return New(config.FirecrackerConfig{
		FirecrackerPath:  "firecracker",
		KernelPath:       testKernelPath(t),
		RootfsImagePath:  testRootfsPath(t),
		VCPUs:            1,
		MemSizeMiB:       256,
		WorkspaceSizeMiB: 64,
	})
}

// --- I1: Filesystem Isolation ---

func TestIntegration_Security_CannotReadHostFiles(t *testing.T) {
	drv := newTestDriver(t)

	facilityDir := t.TempDir()
	logSink := &stubLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// Try to read /etc/hostname inside the VM — it should be the guest hostname,
	// NOT the host hostname.
	hostHostname, _ := os.Hostname()

	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "sec-fs-test",
		Command:       "cat /etc/hostname 2>/dev/null || echo NOFILE",
		FacilityPath:  facilityDir,
		LogSink:       logSink,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	output := logSink.stdout.String()
	if strings.TrimSpace(output) == hostHostname {
		t.Error("SECURITY: guest can read host's /etc/hostname — filesystem isolation broken")
	}

	_ = result
}

// --- I2: Network Isolation ---

func TestIntegration_Security_NoDirectInternet(t *testing.T) {
	drv := newTestDriver(t)

	facilityDir := t.TempDir()
	logSink := &stubLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// Try a direct TCP connection (bypassing proxy). Should fail.
	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID: "sec-net-test",
		Command: `
timeout 5 sh -c 'echo test | nc -w 3 1.1.1.1 80 2>/dev/null' && echo DIRECT_NET_OK || echo DIRECT_NET_BLOCKED
`,
		FacilityPath:  facilityDir,
		LogSink:       logSink,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	output := logSink.stdout.String()
	if strings.Contains(output, "DIRECT_NET_OK") {
		t.Error("SECURITY: guest has direct internet access — network isolation broken")
	}
	if !strings.Contains(output, "DIRECT_NET_BLOCKED") {
		t.Log("WARNING: could not verify direct network is blocked (nc might not be available)")
	}

	_ = result
}

// --- I3: Exit Code Accuracy ---

func TestIntegration_Security_ExitCodeZero(t *testing.T) {
	drv := newTestDriver(t)

	facilityDir := t.TempDir()
	logSink := &stubLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "sec-exit0-test",
		Command:       "exit 0",
		FacilityPath:  facilityDir,
		LogSink:       logSink,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	// Debug: verify exit code marker appears in serial output.
	// Note: nexus-init still emits the generic NEXUS_EXIT_CODE= marker;
	// the nonce-tagged marker from run.sh is what the host actually parses.
	stdout := logSink.stdout.String()
	if strings.Contains(stdout, "NEXUS_EXIT_") {
		t.Logf("DEBUG: exit code marker found in serial output")
	} else {
		t.Logf("DEBUG: exit code marker NOT found in stdout — using fallback")
	}

	if result.ExitCode != 0 {
		t.Errorf("SECURITY: exit code should be 0, got %d", result.ExitCode)
	}
	if result.Status != "succeeded" {
		t.Errorf("SECURITY: status should be succeeded, got %s", result.Status)
	}
}

func TestIntegration_Security_ExitCodeNonZero(t *testing.T) {
	drv := newTestDriver(t)

	facilityDir := t.TempDir()
	logSink := &stubLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "sec-exit42-test",
		Command:       "exit 42",
		FacilityPath:  facilityDir,
		LogSink:       logSink,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	// Debug: log captured output to diagnose exit code parsing.
	// The nonce-tagged marker from run.sh is what the host actually parses.
	stdout := logSink.stdout.String()
	if strings.Contains(stdout, "NEXUS_EXIT_") {
		t.Logf("DEBUG: exit code marker found in stdout")
	} else {
		t.Logf("DEBUG: exit code marker NOT found in captured stdout (%d bytes)", len(stdout))
		if len(stdout) > 500 {
			t.Logf("DEBUG: stdout tail: %q", stdout[len(stdout)-500:])
		} else {
			t.Logf("DEBUG: full stdout: %q", stdout)
		}
	}

	if result.ExitCode != 42 {
		t.Errorf("SECURITY: exit code should be 42, got %d", result.ExitCode)
	}
	if result.Status != "failed" {
		t.Errorf("SECURITY: status should be failed, got %s", result.Status)
	}
}

// --- I4: Workspace Sync ---

func TestIntegration_Security_WorkspaceWriteVisible(t *testing.T) {
	drv := newTestDriver(t)

	facilityDir := t.TempDir()
	logSink := &stubLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "sec-ws-write-test",
		Command:       "echo 'workspace-canary' > /workspace/canary.txt",
		FacilityPath:  facilityDir,
		LogSink:       logSink,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if result.ExitCode != 0 {
		t.Fatalf("command failed with exit code %d", result.ExitCode)
	}

	// Verify the file was extracted back.
	content, err := os.ReadFile(filepath.Join(facilityDir, "canary.txt"))
	if err != nil {
		t.Fatalf("canary.txt not extracted back: %v", err)
	}
	if !strings.Contains(string(content), "workspace-canary") {
		t.Error("canary.txt content mismatch after extraction")
	}
}

func TestIntegration_Security_RootfsWriteNotPersisted(t *testing.T) {
	drv := newTestDriver(t)

	facilityDir := t.TempDir()
	logSink := &stubLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// Try to write to rootfs — should fail (read-only) or succeed on tmpfs
	// but NOT persist to the host rootfs image.
	_, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "sec-rootfs-test",
		Command:       "touch /root-test-marker 2>/dev/null; echo done",
		FacilityPath:  facilityDir,
		LogSink:       logSink,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	// The marker must NOT appear on the host or in the facility dir.
	if _, err := os.Stat("/root-test-marker"); err == nil {
		t.Fatal("SECURITY: guest was able to write to host filesystem!")
	}
	if _, err := os.Stat(filepath.Join(facilityDir, "root-test-marker")); err == nil {
		t.Fatal("SECURITY: rootfs write leaked to facility directory!")
	}
}

// --- I5: Timeout Enforcement ---

func TestIntegration_Security_TimeoutEnforced(t *testing.T) {
	drv := newTestDriver(t)

	facilityDir := t.TempDir()
	logSink := &stubLogSink{}

	// 15s timeout for a command that sleeps for 600s.
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "sec-timeout-test",
		Command:       "sleep 600",
		FacilityPath:  facilityDir,
		LogSink:       logSink,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if result.Status != "timed_out" {
		t.Errorf("SECURITY: expected timed_out status, got %q", result.Status)
	}
	if result.ExitCode != 124 {
		t.Errorf("SECURITY: expected exit code 124 for timeout, got %d", result.ExitCode)
	}
}
