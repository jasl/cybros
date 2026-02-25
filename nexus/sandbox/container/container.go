//go:build linux

package container

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"syscall"
	"time"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/egressproxy"
	"cybros.ai/nexus/sandbox"
)

// Driver implements sandbox.Driver using rootless Podman/Docker for trusted workloads.
// Network constraint is soft (proxy env injection), not hard (no network namespace isolation).
type Driver struct {
	cfg config.ContainerConfig
}

// New creates a container Driver with the given config.
func New(cfg config.ContainerConfig) *Driver {
	return &Driver{cfg: cfg}
}

// Name returns "container".
func (d *Driver) Name() string { return "container" }

// HealthCheck verifies that the container runtime is available and the image exists.
func (d *Driver) HealthCheck(ctx context.Context) sandbox.HealthResult {
	details := map[string]string{"driver": "container"}

	runtime := d.cfg.Runtime
	if runtime == "" {
		runtime = "podman"
	}

	// 1. Check runtime binary exists.
	resolvedPath, err := exec.LookPath(runtime)
	if err != nil {
		details["error"] = runtime + " not found in PATH"
		return sandbox.HealthResult{Healthy: false, Details: details}
	}
	details["runtime_path"] = resolvedPath

	// 2. Check container image availability.
	image := d.cfg.Image
	if image == "" {
		image = "ubuntu:24.04"
	}

	testCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(testCtx, runtime, "image", "exists", image)
	if err := cmd.Run(); err != nil {
		details["error"] = "image " + image + " not available locally"
		return sandbox.HealthResult{Healthy: false, Details: details}
	}

	return sandbox.HealthResult{Healthy: true, Details: details}
}

type truncationReporter interface {
	StdoutTruncated() bool
	StderrTruncated() bool
}

// Run executes a command inside a rootless container with proxy env injection.
func (d *Driver) Run(ctx context.Context, req sandbox.RunRequest) (sandbox.RunResult, error) {
	if req.Command == "" {
		return sandbox.RunResult{}, errors.New("empty command")
	}
	if req.LogSink == nil {
		return sandbox.RunResult{}, errors.New("LogSink is required")
	}
	if req.FacilityPath == "" {
		return sandbox.RunResult{}, errors.New("FacilityPath is required for container driver")
	}

	// 1. Start egress proxy if proxy mode is "env".
	var proxyURL string
	var proxyInst *egressproxy.Instance
	if d.cfg.ProxyMode == "env" {
		auditWriter := io.Discard
		if u, ok := req.LogSink.(interface {
			UploadBytes(context.Context, string, []byte)
		}); ok {
			auditWriter = logSinkWriter{ctx: ctx, uploader: u, stream: "stderr"}
		}

		var err error
		proxyInst, err = egressproxy.StartForDirectiveTCP(
			req.DirectiveID, req.NetCapability, auditWriter,
		)
		if err != nil {
			return sandbox.RunResult{}, fmt.Errorf("start egress proxy: %w", err)
		}
		defer proxyInst.Stop()
		proxyURL = proxyInst.ProxyURL()
	}

	// 2. Prepare git clone args if needed.
	var cloneArgs []string
	var cloneEnv []string
	if req.RepoURL != "" {
		var err error
		cloneArgs, cloneEnv, err = sandbox.PrepareGitCloneArgs(req.RepoURL)
		if err != nil {
			return sandbox.RunResult{}, fmt.Errorf("prepare git clone: %w", err)
		}
	}

	// 3. Build container run args.
	cmdArgs, err := BuildArgs(CmdConfig{
		Runtime:      d.cfg.Runtime,
		Image:        d.cfg.Image,
		FacilityPath: req.FacilityPath,
		Command:      req.Command,
		Shell:        req.Shell,
		Cwd:          req.Cwd,
		Env:          req.Env,
		ProxyMode:    d.cfg.ProxyMode,
		ProxyURL:     proxyURL,
		RepoURL:      req.RepoURL,
		GitCloneArgs: cloneArgs,
		GitCloneEnv:  cloneEnv,
	})
	if err != nil {
		return sandbox.RunResult{}, fmt.Errorf("build container args: %w", err)
	}

	// 4. Execute the container.
	cmd := exec.CommandContext(ctx, cmdArgs[0], cmdArgs[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
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
		return sandbox.RunResult{}, fmt.Errorf("start container: %w", err)
	}

	// Stream logs concurrently.
	errCh := make(chan error, 2)
	go func() { errCh <- req.LogSink.Consume(ctx, "stdout", stdout) }()
	go func() { errCh <- req.LogSink.Consume(ctx, "stderr", stderr) }()

	consume1 := <-errCh
	consume2 := <-errCh

	waitErr := cmd.Wait()

	result := sandbox.RunResult{
		ExitCode: exitCode(waitErr),
		Status:   statusFrom(waitErr, ctx),
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
