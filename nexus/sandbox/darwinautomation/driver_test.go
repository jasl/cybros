package darwinautomation

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"cybros.ai/nexus/sandbox"
)

func TestDriver_Name(t *testing.T) {
	t.Parallel()

	drv := New()
	if drv.Name() != "darwin-automation" {
		t.Fatalf("expected name darwin-automation, got %s", drv.Name())
	}
}

func TestDriver_HealthCheck(t *testing.T) {
	t.Parallel()

	drv := New()
	result := drv.HealthCheck(context.Background())

	if !result.Healthy {
		t.Fatal("expected healthy=true")
	}
	if result.Details["driver"] != "darwin-automation" {
		t.Fatalf("expected driver=darwin-automation in details, got %v", result.Details)
	}
}

func TestDriver_Run_SimpleCommand(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()
	sink := &sandbox.DiscardSink{}

	res, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "echo hello",
		Shell:   "/bin/sh",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", res.ExitCode)
	}
	if res.Status != "succeeded" {
		t.Fatalf("expected status succeeded, got %s", res.Status)
	}
}

func TestDriver_Run_FailedCommand(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()
	sink := &sandbox.DiscardSink{}

	res, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "exit 42",
		Shell:   "/bin/sh",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ExitCode != 42 {
		t.Fatalf("expected exit code 42, got %d", res.ExitCode)
	}
	if res.Status != "failed" {
		t.Fatalf("expected status failed, got %s", res.Status)
	}
}

func TestDriver_Run_EmptyCommand(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()
	sink := &sandbox.DiscardSink{}

	_, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err == nil {
		t.Fatal("expected error for empty command")
	}
}

func TestDriver_Run_NilLogSink(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()

	_, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "echo hello",
		WorkDir: workDir,
		LogSink: nil,
	})
	if err == nil {
		t.Fatal("expected error for nil LogSink")
	}
}

func TestDriver_Run_MinimalEnv(t *testing.T) {
	// Cannot use t.Parallel() with t.Setenv().
	t.Setenv("SUPER_SECRET_KEY", "should-not-leak")

	drv := New()
	workDir := t.TempDir()

	scriptPath := filepath.Join(workDir, "check.sh")
	_ = os.WriteFile(scriptPath, []byte("#!/bin/sh\necho ${SUPER_SECRET_KEY:-not_found}"), 0o755)

	sink := &sandbox.DiscardSink{}
	res, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "sh " + scriptPath,
		Shell:   "/bin/sh",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", res.ExitCode)
	}
}

func TestDriver_Run_Timeout(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()
	sink := &sandbox.DiscardSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	res, err := drv.Run(ctx, sandbox.RunRequest{
		Command: "sleep 30",
		Shell:   "/bin/sh",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Status != "timed_out" {
		t.Fatalf("expected status timed_out, got %s", res.Status)
	}
	if res.ExitCode != 124 {
		t.Fatalf("expected exit code 124, got %d", res.ExitCode)
	}
}

func TestDriver_Run_DefaultShell(t *testing.T) {
	t.Parallel()

	// The default shell is /bin/zsh which is only guaranteed on macOS.
	if runtime.GOOS != "darwin" {
		if _, err := exec.LookPath("zsh"); err != nil {
			t.Skip("zsh not available on this platform")
		}
	}

	drv := New()
	workDir := t.TempDir()
	sink := &sandbox.DiscardSink{}

	res, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "echo $0",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", res.ExitCode)
	}
}

func TestDriver_Run_CustomShell(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()
	sink := &sandbox.DiscardSink{}

	res, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "echo hello",
		Shell:   "/bin/sh",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", res.ExitCode)
	}
}

func TestDriver_Run_CwdResolution(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()
	subDir := filepath.Join(workDir, "sub")
	_ = os.MkdirAll(subDir, 0o755)

	sink := &sandbox.DiscardSink{}
	res, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "pwd",
		Shell:   "/bin/sh",
		Cwd:     "sub",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", res.ExitCode)
	}
}

func TestDriver_Run_CwdEscape(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()
	sink := &sandbox.DiscardSink{}

	_, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "pwd",
		Shell:   "/bin/sh",
		Cwd:     "../escape",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err == nil {
		t.Fatal("expected error for CWD escape")
	}
}

func TestDriver_Run_Cancel(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()
	sink := &sandbox.DiscardSink{}

	ctx, cancel := context.WithCancel(context.Background())

	// Cancel after a short delay while the command is running.
	go func() {
		time.Sleep(100 * time.Millisecond)
		cancel()
	}()

	res, err := drv.Run(ctx, sandbox.RunRequest{
		Command: "sleep 30",
		Shell:   "/bin/sh",
		WorkDir: workDir,
		LogSink: sink,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Status != "canceled" {
		t.Fatalf("expected status canceled, got %s", res.Status)
	}
}

func TestDriver_Run_EnvOverride(t *testing.T) {
	t.Parallel()

	drv := New()
	workDir := t.TempDir()
	sink := &sandbox.DiscardSink{}

	res, err := drv.Run(context.Background(), sandbox.RunRequest{
		Command: "echo $MY_CUSTOM_VAR",
		Shell:   "/bin/sh",
		WorkDir: workDir,
		LogSink: sink,
		Env:     map[string]string{"MY_CUSTOM_VAR": "injected_value"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", res.ExitCode)
	}
}

func TestDriver_MinimalDarwinEnv(t *testing.T) {
	t.Parallel()

	env := minimalDarwinEnv()

	// PATH should always be present.
	if _, ok := env["PATH"]; !ok {
		t.Error("expected PATH in minimal env")
	}

	// Should not contain typical secrets.
	sensitiveKeys := []string{"AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "DATABASE_URL", "API_KEY"}
	for _, key := range sensitiveKeys {
		if _, ok := env[key]; ok {
			t.Errorf("minimal env should not contain %s", key)
		}
	}

	// Only allowlisted keys should be present.
	allowed := map[string]bool{
		"PATH": true, "HOME": true, "USER": true, "LOGNAME": true,
		"SHELL": true, "TMPDIR": true, "LANG": true, "LC_ALL": true,
		"SSH_AUTH_SOCK": true,
	}
	for key := range env {
		if !allowed[key] {
			t.Errorf("unexpected key %q in minimal env", key)
		}
	}
}
