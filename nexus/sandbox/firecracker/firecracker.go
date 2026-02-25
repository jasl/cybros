//go:build linux

package firecracker

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/egressproxy"
	"cybros.ai/nexus/sandbox"
)

// Driver implements sandbox.Driver using Firecracker microVMs.
type Driver struct {
	cfg config.FirecrackerConfig
}

// New creates a Firecracker Driver with the given config.
func New(cfg config.FirecrackerConfig) *Driver {
	return &Driver{cfg: cfg}
}

// Name returns "firecracker".
func (d *Driver) Name() string { return "firecracker" }

// HealthCheck verifies KVM access, firecracker binary, and VM assets.
func (d *Driver) HealthCheck(ctx context.Context) sandbox.HealthResult {
	details := map[string]string{"driver": "firecracker"}

	// 1. Check /dev/kvm is accessible for read/write.
	f, err := os.OpenFile("/dev/kvm", os.O_RDWR, 0)
	if err != nil {
		details["error"] = "/dev/kvm not accessible: " + err.Error()
		return sandbox.HealthResult{Healthy: false, Details: details}
	}
	defer f.Close()

	// 2. Check firecracker binary exists.
	fcPath := d.cfg.FirecrackerPath
	if fcPath == "" {
		fcPath = "firecracker"
	}
	resolvedPath, err := exec.LookPath(fcPath)
	if err != nil {
		details["error"] = "firecracker binary not found in PATH"
		return sandbox.HealthResult{Healthy: false, Details: details}
	}
	details["firecracker_path"] = resolvedPath

	// 3. Check kernel image exists.
	if d.cfg.KernelPath == "" {
		details["error"] = "kernel_path not configured"
		return sandbox.HealthResult{Healthy: false, Details: details}
	}
	if _, err := os.Stat(d.cfg.KernelPath); err != nil {
		details["error"] = "kernel not found: " + d.cfg.KernelPath
		return sandbox.HealthResult{Healthy: false, Details: details}
	}

	// 4. Check rootfs image exists.
	if d.cfg.RootfsImagePath == "" {
		details["error"] = "rootfs_image_path not configured"
		return sandbox.HealthResult{Healthy: false, Details: details}
	}
	if _, err := os.Stat(d.cfg.RootfsImagePath); err != nil {
		details["error"] = "rootfs image not found: " + d.cfg.RootfsImagePath
		return sandbox.HealthResult{Healthy: false, Details: details}
	}

	// 5. Check mke2fs (needed for workspace images).
	if _, err := exec.LookPath("mke2fs"); err != nil {
		details["warning"] = "mke2fs not found (needed for workspace ext4 images)"
	}

	return sandbox.HealthResult{Healthy: true, Details: details}
}

type truncationReporter interface {
	StdoutTruncated() bool
	StderrTruncated() bool
}

// Run executes a command inside a Firecracker microVM.
func (d *Driver) Run(ctx context.Context, req sandbox.RunRequest) (sandbox.RunResult, error) {
	if req.Command == "" {
		return sandbox.RunResult{}, errors.New("empty command")
	}
	if req.LogSink == nil {
		return sandbox.RunResult{}, errors.New("LogSink is required")
	}
	if req.FacilityPath == "" {
		return sandbox.RunResult{}, errors.New("FacilityPath is required for firecracker driver")
	}

	// 1. Create temp dir for ephemeral files.
	tmpDir, err := os.MkdirTemp("", "nexus-fc-"+req.DirectiveID+"-")
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	// 2. Start the egress proxy (UDS mode).
	proxySocketDir := d.proxySocketDir(req)

	auditWriter := io.Discard
	if u, ok := req.LogSink.(interface {
		UploadBytes(context.Context, string, []byte)
	}); ok {
		auditWriter = logSinkWriter{ctx: ctx, uploader: u, stream: "stderr"}
	}

	proxyInst, err := egressproxy.StartForDirective(
		proxySocketDir, req.DirectiveID, req.NetCapability, auditWriter,
	)
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("start egress proxy: %w", err)
	}
	defer proxyInst.Stop()

	// 3. Start the vsock bridge (vsock UDS → egress proxy UDS).
	vsockPath := filepath.Join(tmpDir, "vsock.sock")
	vsockListenPath := vsockPath + "_9080"

	bridge, err := egressproxy.StartVsockBridge(ctx, vsockListenPath, proxyInst.SocketPath())
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("start vsock bridge: %w", err)
	}
	defer bridge.Stop()

	// 4. Generate wrapper script → create command ext4 image.
	//    Include a per-execution nonce to prevent exit code spoofing.
	nonce, err := generateNonce()
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("generate nonce: %w", err)
	}
	exitMarker := "NEXUS_EXIT_" + nonce + "="

	resolvedCwd, err := resolveCwd(req.Cwd)
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("resolve cwd: %w", err)
	}

	wrapperCfg := WrapperConfig{
		UserCommand: req.Command,
		Shell:       req.Shell,
		Env:         req.Env,
		Cwd:         resolvedCwd,
		ExitMarker:  exitMarker,
	}

	if req.RepoURL != "" {
		cloneArgs, cloneEnv, cloneErr := sandbox.PrepareGitCloneArgs(req.RepoURL)
		if cloneErr != nil {
			return sandbox.RunResult{}, fmt.Errorf("prepare git clone: %w", cloneErr)
		}
		wrapperCfg.RepoURL = req.RepoURL
		wrapperCfg.GitCloneArgs = cloneArgs
		wrapperCfg.GitCloneEnv = cloneEnv
	}

	wrapperScript, err := GenerateWrapper(wrapperCfg)
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("generate wrapper: %w", err)
	}

	cmdDir := filepath.Join(tmpDir, "cmd")
	if err := os.MkdirAll(cmdDir, 0o755); err != nil {
		return sandbox.RunResult{}, fmt.Errorf("create cmd dir: %w", err)
	}
	if err := os.WriteFile(filepath.Join(cmdDir, "run.sh"), []byte(wrapperScript), 0o755); err != nil {
		return sandbox.RunResult{}, fmt.Errorf("write wrapper script: %w", err)
	}

	cmdImagePath := filepath.Join(tmpDir, "cmd.ext4")
	if err := CreateImageFromDir(cmdDir, cmdImagePath, 1); err != nil {
		return sandbox.RunResult{}, fmt.Errorf("create cmd image: %w", err)
	}

	// 5. Create workspace ext4 image from facility directory.
	wsImagePath := filepath.Join(tmpDir, "workspace.ext4")
	wsSizeMiB := d.cfg.WorkspaceSizeMiB
	if wsSizeMiB <= 0 {
		wsSizeMiB = 2048
	}
	if err := CreateImageFromDir(req.FacilityPath, wsImagePath, wsSizeMiB); err != nil {
		return sandbox.RunResult{}, fmt.Errorf("create workspace image: %w", err)
	}

	// 6. Build VM config JSON.
	vmCfg := BuildVMConfig(VMConfigInput{
		KernelPath:   d.cfg.KernelPath,
		RootfsPath:   d.cfg.RootfsImagePath,
		CmdImagePath: cmdImagePath,
		WsImagePath:  wsImagePath,
		VCPUs:        d.vcpus(),
		MemSizeMiB:   d.memSizeMiB(),
		VsockUDSPath: vsockPath,
	})

	cfgData, err := MarshalVMConfig(vmCfg)
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("marshal VM config: %w", err)
	}

	cfgPath := filepath.Join(tmpDir, "vm-config.json")
	if err := os.WriteFile(cfgPath, cfgData, 0o644); err != nil {
		return sandbox.RunResult{}, fmt.Errorf("write VM config: %w", err)
	}

	// 7. Start firecracker.
	fcPath := d.cfg.FirecrackerPath
	if fcPath == "" {
		fcPath = "firecracker"
	}

	cmd := exec.CommandContext(ctx, fcPath, "--no-api", "--config-file", cfgPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Env = minimalExecEnv()
	cmd.Cancel = func() error {
		pgid, err := syscall.Getpgid(cmd.Process.Pid)
		if err == nil {
			return syscall.Kill(-pgid, syscall.SIGKILL)
		}
		return cmd.Process.Kill()
	}

	// Serial console output goes to stdout.
	// We need to both stream it to the LogSink and capture NEXUS_EXIT_CODE.
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return sandbox.RunResult{}, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return sandbox.RunResult{}, err
	}

	if err := cmd.Start(); err != nil {
		return sandbox.RunResult{}, fmt.Errorf("start firecracker: %w", err)
	}

	// 8. Stream logs and capture exit code from serial output.
	serialCapture := newExitCodeCapture(exitMarker)
	tee := io.TeeReader(stdout, serialCapture)

	errCh := make(chan error, 2)
	go func() { errCh <- req.LogSink.Consume(ctx, "stdout", tee) }()
	go func() { errCh <- req.LogSink.Consume(ctx, "stderr", stderr) }()

	consume1 := <-errCh
	consume2 := <-errCh

	waitErr := cmd.Wait()

	// Parse exit code from captured serial output (nonce-tagged marker).
	serialCapture.Flush()
	capturedCode := serialCapture.ExitCode()

	exitCode := 1 // default to failure
	if capturedCode >= 0 {
		exitCode = capturedCode
	} else if waitErr == nil {
		exitCode = 0
	} else {
		exitCode = processExitCode(waitErr)
	}

	// Derive status: use captured exit code when the VM terminated normally.
	status := statusFrom(waitErr, ctx)
	if exitCode != 0 && status == "succeeded" {
		status = "failed"
	}

	result := sandbox.RunResult{
		ExitCode: exitCode,
		Status:   status,
	}

	if tr, ok := req.LogSink.(truncationReporter); ok {
		result.StdoutTruncated = tr.StdoutTruncated()
		result.StderrTruncated = tr.StderrTruncated()
	}

	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		result.Status = "timed_out"
		result.ExitCode = 124
	}
	if errors.Is(ctx.Err(), context.Canceled) && result.Status != "timed_out" {
		result.Status = "canceled"
	}

	// 9. Extract workspace changes back to facility directory.
	if result.Status == "succeeded" || result.Status == "failed" {
		if extractErr := ExtractImageToDir(wsImagePath, req.FacilityPath); extractErr != nil {
			// Log but don't fail the directive — the command itself succeeded/failed.
			// Surface as a warning so callers can report it.
			msg := fmt.Sprintf("workspace extraction error: %v", extractErr)
			fmt.Fprintf(os.Stderr, "firecracker: %s\n", msg)
			result.Warnings = append(result.Warnings, msg)
		}
	}

	consumeErr := errors.Join(consume1, consume2)
	if consumeErr != nil {
		return result, consumeErr
	}

	return result, nil
}

func (d *Driver) proxySocketDir(req sandbox.RunRequest) string {
	if d.cfg.ProxySocketDir != "" {
		return d.cfg.ProxySocketDir
	}
	return filepath.Join(filepath.Dir(req.FacilityPath), ".proxy-sockets")
}

func (d *Driver) vcpus() int {
	if d.cfg.VCPUs > 0 {
		return d.cfg.VCPUs
	}
	return 2
}

func (d *Driver) memSizeMiB() int {
	if d.cfg.MemSizeMiB > 0 {
		return d.cfg.MemSizeMiB
	}
	return 512
}

type logSinkWriter struct {
	ctx      context.Context
	uploader interface {
		UploadBytes(context.Context, string, []byte)
	}
	stream string
}

func (w logSinkWriter) Write(p []byte) (int, error) {
	w.uploader.UploadBytes(w.ctx, w.stream, p)
	return len(p), nil
}

func statusFrom(waitErr error, ctx context.Context) string {
	if waitErr == nil {
		return "succeeded"
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return "timed_out"
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		return "canceled"
	}
	return "failed"
}

// generateNonce returns a random 16-character hex string for exit code markers.
func generateNonce() (string, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func processExitCode(waitErr error) int {
	if waitErr == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(waitErr, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok {
			if ws.Exited() {
				return ws.ExitStatus()
			}
			if ws.Signaled() {
				return 128 + int(ws.Signal())
			}
		}
	}
	return 1
}
