//go:build linux

package bwrap

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/egressproxy"
	"cybros.ai/nexus/sandbox"
)

// Driver implements sandbox.Driver using bubblewrap for untrusted workloads.
type Driver struct {
	cfg config.BwrapConfig
}

// New creates a bubblewrap Driver with the given config.
func New(cfg config.BwrapConfig) *Driver {
	return &Driver{cfg: cfg}
}

// Name returns "bwrap".
func (d *Driver) Name() string { return "bwrap" }

// HealthCheck verifies that bwrap is installed and can create namespaces.
func (d *Driver) HealthCheck(ctx context.Context) sandbox.HealthResult {
	details := map[string]string{"driver": "bwrap"}

	bwrapPath := d.cfg.BwrapPath
	if bwrapPath == "" {
		bwrapPath = "bwrap"
	}

	// 1. Check bwrap binary exists.
	resolvedPath, err := exec.LookPath(bwrapPath)
	if err != nil {
		details["error"] = "bwrap not found in PATH"
		return sandbox.HealthResult{Healthy: false, Details: details}
	}
	details["bwrap_path"] = resolvedPath

	// 2. Functional namespace test (reuses pattern from doctor_linux.go).
	testCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(testCtx, bwrapPath,
		"--ro-bind", "/", "/",
		"--proc", "/proc",
		"--dev", "/dev",
		"--tmpfs", "/tmp",
		"--unshare-net",
		"--unshare-pid",
		"--new-session",
		"--die-with-parent",
		"--cap-drop", "ALL",
		"--", "/bin/echo", "ok",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		details["error"] = fmt.Sprintf("namespace test failed: %v (output: %s)", err, string(out))
		return sandbox.HealthResult{Healthy: false, Details: details}
	}

	// 3. Check rootfs if configured — missing bin/sh means the wrapper script cannot execute.
	if d.cfg.RootfsPath != "" {
		shPath := filepath.Join(d.cfg.RootfsPath, "bin", "sh")
		if _, err := os.Stat(shPath); err != nil {
			details["error"] = "rootfs missing bin/sh at " + d.cfg.RootfsPath
			return sandbox.HealthResult{Healthy: false, Details: details}
		}
	}

	return sandbox.HealthResult{Healthy: true, Details: details}
}

type truncationReporter interface {
	StdoutTruncated() bool
	StderrTruncated() bool
}

// Run executes a command inside a bubblewrap sandbox.
func (d *Driver) Run(ctx context.Context, req sandbox.RunRequest) (sandbox.RunResult, error) {
	if req.Command == "" {
		return sandbox.RunResult{}, errors.New("empty command")
	}
	if req.LogSink == nil {
		return sandbox.RunResult{}, errors.New("LogSink is required")
	}
	if req.FacilityPath == "" {
		return sandbox.RunResult{}, errors.New("FacilityPath is required for bwrap driver")
	}

	// 1. Start the egress proxy for this directive.
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

	// 2. Prepare git clone args if needed.
	var wrapperCfg WrapperConfig
	wrapperCfg.SocatPath = d.cfg.SocatPath
	wrapperCfg.UserCommand = req.Command
	wrapperCfg.Shell = req.Shell
	wrapperCfg.Env = req.Env

	resolvedCwd, err := resolveCwd(req.Cwd)
	if err != nil {
		return sandbox.RunResult{}, err
	}
	wrapperCfg.Cwd = resolvedCwd

	if req.RepoURL != "" {
		cloneArgs, cloneEnv, cloneErr := sandbox.PrepareGitCloneArgs(req.RepoURL)
		if cloneErr != nil {
			return sandbox.RunResult{}, fmt.Errorf("prepare git clone: %w", cloneErr)
		}
		wrapperCfg.RepoURL = req.RepoURL
		wrapperCfg.GitCloneArgs = cloneArgs
		wrapperCfg.GitCloneEnv = cloneEnv
	}

	// 3. Generate the wrapper script.
	wrapperScript, err := GenerateWrapper(wrapperCfg)
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("generate wrapper: %w", err)
	}

	// Write the wrapper to a temp file.
	wrapperFile, err := os.CreateTemp("", "nexus-wrapper-*.sh")
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("create wrapper file: %w", err)
	}
	defer os.Remove(wrapperFile.Name())

	if _, err := wrapperFile.WriteString(wrapperScript); err != nil {
		wrapperFile.Close()
		return sandbox.RunResult{}, fmt.Errorf("write wrapper: %w", err)
	}
	if err := wrapperFile.Close(); err != nil {
		return sandbox.RunResult{}, fmt.Errorf("close wrapper: %w", err)
	}

	// 4. Build bwrap command.
	bwrapArgs, err := BuildArgs(CmdConfig{
		BwrapPath:         d.cfg.BwrapPath,
		RootfsPath:        d.cfg.RootfsPath,
		FacilityPath:      req.FacilityPath,
		ProxySocketPath:   proxyInst.SocketPath(),
		WrapperScriptPath: wrapperFile.Name(),
		Cwd:               req.Cwd,
		HostHasLib64:      hostHasLib64(),
	})
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("build bwrap args: %w", err)
	}

	// 5. Execute bwrap.
	cmd := exec.CommandContext(ctx, bwrapArgs[0], bwrapArgs[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Env = minimalExecEnv()
	cmd.Cancel = func() error {
		pgid, err := syscall.Getpgid(cmd.Process.Pid)
		if err == nil {
			return syscall.Kill(-pgid, syscall.SIGKILL)
		}
		return cmd.Process.Kill()
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return sandbox.RunResult{}, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return sandbox.RunResult{}, err
	}

	if err := cmd.Start(); err != nil {
		return sandbox.RunResult{}, fmt.Errorf("start bwrap: %w", err)
	}

	// Apply cgroup v2 limits if specified (Linux only; no-op on other platforms).
	// Fail-closed: if limits were explicitly requested but couldn't be applied,
	// abort the directive rather than running without resource constraints.
	var warnings []string
	cg, cgErr := sandbox.ApplyCgroupLimits(req.DirectiveID, cmd.Process.Pid, req.Limits)
	if cgErr != nil {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
		return sandbox.RunResult{}, fmt.Errorf("cgroup limits required but failed to apply: %w", cgErr)
	}
	if cg != nil {
		defer cg.Cleanup()
	}

	// Stream logs concurrently.
	errCh := make(chan error, 2)
	go func() { errCh <- req.LogSink.Consume(ctx, "stdout", stdout) }()
	go func() { errCh <- req.LogSink.Consume(ctx, "stderr", stderr) }()

	// Drain pipe readers BEFORE cmd.Wait() (same pattern as host driver).
	consume1 := <-errCh
	consume2 := <-errCh

	waitErr := cmd.Wait()

	result := sandbox.RunResult{
		ExitCode: exitCode(waitErr),
		Status:   statusFrom(waitErr, ctx),
		Warnings: warnings,
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

func minimalExecEnv() []string {
	return []string{
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME=/",
		"LANG=C",
		"LC_ALL=C",
	}
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

func hostHasLib64() bool {
	fi, err := os.Lstat("/lib64")
	return err == nil && fi.Mode()&os.ModeSymlink != 0
}

func exitCode(waitErr error) int {
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
