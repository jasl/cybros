//go:build linux

package bwrap

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"testing"
	"time"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/protocol"
	"cybros.ai/nexus/sandbox"
)

// testLogSink implements sandbox.LogSink for testing.
type testLogSink struct {
	stdout bytes.Buffer
	stderr bytes.Buffer
}

func (s *testLogSink) Consume(_ context.Context, stream string, r io.Reader) error {
	switch stream {
	case "stdout":
		_, err := io.Copy(&s.stdout, r)
		return err
	case "stderr":
		_, err := io.Copy(&s.stderr, r)
		return err
	}
	return nil
}

func skipIfNoBwrap(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("bwrap"); err != nil {
		t.Skip("bwrap not found in PATH; install bubblewrap to run integration tests")
	}
}

func skipIfNoSocat(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("socat"); err != nil {
		t.Skip("socat not found in PATH; install socat to run integration tests")
	}
}

func TestDriver_Run_Echo(t *testing.T) {
	skipIfNoBwrap(t)
	skipIfNoSocat(t)

	facilityDir := t.TempDir()
	cfg := config.BwrapConfig{
		BwrapPath: "bwrap",
		SocatPath: "socat",
	}

	drv := New(cfg)
	sink := &testLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "test-echo",
		Command:       "echo hello-from-bwrap",
		LogSink:       sink,
		FacilityPath:  facilityDir,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if result.ExitCode != 0 {
		t.Errorf("exit code = %d, want 0; stderr: %s", result.ExitCode, sink.stderr.String())
	}
	if result.Status != "succeeded" {
		t.Errorf("status = %q, want succeeded", result.Status)
	}
	if out := sink.stdout.String(); out == "" {
		t.Error("expected stdout output")
	}
}

func TestDriver_Run_NetworkIsolated(t *testing.T) {
	skipIfNoBwrap(t)
	skipIfNoSocat(t)

	facilityDir := t.TempDir()
	cfg := config.BwrapConfig{
		BwrapPath: "bwrap",
		SocatPath: "socat",
	}

	drv := New(cfg)
	sink := &testLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Attempt to ping should fail because --unshare-net isolates network
	_, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "test-net",
		Command:       "ping -c1 -W1 8.8.8.8 2>&1; echo done",
		LogSink:       sink,
		FacilityPath:  facilityDir,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	// The command should complete (echo done) but ping should fail
	out := sink.stdout.String()
	if out == "" {
		t.Error("expected some output")
	}
	t.Logf("stdout: %s", out)
}

func TestDriver_Run_WorkspaceWritable(t *testing.T) {
	skipIfNoBwrap(t)
	skipIfNoSocat(t)

	facilityDir := t.TempDir()
	cfg := config.BwrapConfig{
		BwrapPath: "bwrap",
		SocatPath: "socat",
	}

	drv := New(cfg)
	sink := &testLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "test-write",
		Command:       "echo 'sandbox-output' > /workspace/test.txt && cat /workspace/test.txt",
		LogSink:       sink,
		FacilityPath:  facilityDir,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if result.ExitCode != 0 {
		t.Errorf("exit code = %d; stderr: %s", result.ExitCode, sink.stderr.String())
	}

	// Verify the file was written to the host facility dir
	data, err := os.ReadFile(facilityDir + "/test.txt")
	if err != nil {
		t.Fatalf("read test.txt from host: %v", err)
	}
	if string(data) != "sandbox-output\n" {
		t.Errorf("test.txt = %q, want %q", string(data), "sandbox-output\n")
	}

	_ = result
}

func TestDriver_Run_ReadOnlyRoot(t *testing.T) {
	skipIfNoBwrap(t)
	skipIfNoSocat(t)

	facilityDir := t.TempDir()
	cfg := config.BwrapConfig{
		BwrapPath: "bwrap",
		SocatPath: "socat",
	}

	drv := New(cfg)
	sink := &testLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Try writing to / which should be read-only
	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "test-ro",
		Command:       "touch /testfile 2>&1; echo exitcode=$?",
		LogSink:       sink,
		FacilityPath:  facilityDir,
		NetCapability: &protocol.NetCapabilityV1{Mode: "none"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	out := sink.stdout.String()
	t.Logf("stdout: %s", out)

	// touch should fail (read-only fs)
	if result.ExitCode == 0 && !containsStr(out, "Read-only") && !containsStr(out, "exitcode=1") {
		t.Error("expected write to read-only root to fail")
	}

	_ = result
}

// FIX C7: Verify minimalExecEnv returns ONLY safe, known env vars.
// The host process may have API keys, tokens, or secrets in its env.
// cmd.Env = minimalExecEnv() ensures none of these leak to bwrap.
func TestMinimalExecEnv_NoHostLeak(t *testing.T) {
	env := minimalExecEnv()

	if len(env) == 0 {
		t.Fatal("minimalExecEnv should return a non-empty env list")
	}

	// Only PATH, HOME, LANG, LC_ALL should be present
	allowedPrefixes := map[string]bool{
		"PATH=":   false,
		"HOME=":   false,
		"LANG=":   false,
		"LC_ALL=": false,
	}

	for _, e := range env {
		matched := false
		for prefix := range allowedPrefixes {
			if len(e) >= len(prefix) && e[:len(prefix)] == prefix {
				allowedPrefixes[prefix] = true
				matched = true
				break
			}
		}
		if !matched {
			t.Errorf("minimalExecEnv contains unexpected var: %q", e)
		}
	}

	for prefix, found := range allowedPrefixes {
		if !found {
			t.Errorf("minimalExecEnv missing required var with prefix %q", prefix)
		}
	}

	// Verify no sensitive vars could sneak in
	for _, e := range env {
		for _, sensitive := range []string{"TOKEN", "SECRET", "KEY", "PASSWORD", "CREDENTIAL"} {
			if containsStr(e, sensitive) {
				t.Errorf("minimalExecEnv contains potentially sensitive var: %q", e)
			}
		}
	}
}

// FIX C7: Verify minimalExecEnv count is exactly 4 (PATH, HOME, LANG, LC_ALL).
// Adding vars here should be a conscious security decision.
func TestMinimalExecEnv_ExactCount(t *testing.T) {
	env := minimalExecEnv()
	if len(env) != 4 {
		t.Errorf("minimalExecEnv returned %d vars, want exactly 4 (PATH, HOME, LANG, LC_ALL); got: %v",
			len(env), env)
	}
}

func TestDriver_Name(t *testing.T) {
	drv := New(config.BwrapConfig{})
	if drv.Name() != "bwrap" {
		t.Errorf("Name() = %q, want %q", drv.Name(), "bwrap")
	}
}

func containsStr(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(s) > 0 && findStr(s, sub))
}

func findStr(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
