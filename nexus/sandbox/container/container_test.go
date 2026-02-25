//go:build linux

package container

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

func skipIfNoPodman(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("podman"); err != nil {
		t.Skip("podman not found in PATH; install podman to run container integration tests")
	}
}

func TestDriver_Run_Echo(t *testing.T) {
	skipIfNoPodman(t)

	facilityDir := t.TempDir()
	cfg := config.ContainerConfig{
		Runtime:   "podman",
		Image:     "ubuntu:24.04",
		ProxyMode: "none",
	}

	drv := New(cfg)
	sink := &testLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "test-echo",
		Command:       "echo hello-from-container",
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

	out := sink.stdout.String()
	if out == "" {
		t.Error("expected stdout output")
	}
	t.Logf("stdout: %s", out)
}

func TestDriver_Run_WorkspaceMount(t *testing.T) {
	skipIfNoPodman(t)

	facilityDir := t.TempDir()
	// Write a file to facility dir before running
	if err := os.WriteFile(facilityDir+"/input.txt", []byte("test-data"), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg := config.ContainerConfig{
		Runtime:   "podman",
		Image:     "ubuntu:24.04",
		ProxyMode: "none",
	}

	drv := New(cfg)
	sink := &testLogSink{}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	result, err := drv.Run(ctx, sandbox.RunRequest{
		DirectiveID:   "test-mount",
		Command:       "cat /workspace/input.txt && echo output > /workspace/output.txt",
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

	// Verify output was written to host
	data, err := os.ReadFile(facilityDir + "/output.txt")
	if err != nil {
		t.Fatalf("read output.txt: %v", err)
	}
	if string(data) != "output\n" {
		t.Errorf("output.txt = %q, want %q", string(data), "output\n")
	}
}

func TestDriver_Name(t *testing.T) {
	drv := New(config.ContainerConfig{})
	if drv.Name() != "container" {
		t.Errorf("Name() = %q, want %q", drv.Name(), "container")
	}
}
