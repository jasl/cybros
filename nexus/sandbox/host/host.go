package host

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"cybros.ai/nexus/sandbox"
)

type Driver struct{}

func New() *Driver { return &Driver{} }

func (d *Driver) Name() string { return "host" }

// HealthCheck always reports healthy for the host driver (no external deps).
func (d *Driver) HealthCheck(_ context.Context) sandbox.HealthResult {
	return sandbox.HealthResult{
		Healthy: true,
		Details: map[string]string{"driver": "host"},
	}
}

// minimalHostEnv returns the minimum set of environment variables inherited
// from the host process. The host driver does not provide isolation, but
// we avoid leaking the full process environment (which may contain secrets
// like API keys or tokens) into directive commands.
func minimalHostEnv() map[string]string {
	env := map[string]string{}
	for _, key := range []string{
		"PATH", "HOME", "USER", "LOGNAME", "SHELL",
		"TMPDIR", "LANG", "LC_ALL",
	} {
		if v := os.Getenv(key); v != "" {
			env[key] = v
		}
	}
	return env
}

func (d *Driver) Run(ctx context.Context, req sandbox.RunRequest) (sandbox.RunResult, error) {
	if req.Command == "" {
		return sandbox.RunResult{}, errors.New("empty command")
	}
	if req.LogSink == nil {
		return sandbox.RunResult{}, errors.New("LogSink is required")
	}

	// The caller (daemon) is responsible for setting the context deadline.
	// The driver uses the context as-is to avoid double timeouts.

	shell := req.Shell
	if shell == "" {
		shell = "/bin/sh"
	}
	cmd := exec.CommandContext(ctx, shell, "-c", req.Command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		// Kill the entire process group to ensure child processes are also terminated.
		pgid, err := syscall.Getpgid(cmd.Process.Pid)
		if err == nil {
			return syscall.Kill(-pgid, syscall.SIGKILL)
		}
		return cmd.Process.Kill()
	}

	cwd, err := sandbox.ResolveWorkspaceCwd(req.WorkDir, req.Cwd)
	if err != nil {
		return sandbox.RunResult{}, err
	}
	cmd.Dir = cwd

	// Env: start with minimal host env, then apply directive-specific overrides.
	envMap := minimalHostEnv()
	for k, v := range req.Env {
		envMap[k] = v
	}
	env := make([]string, 0, len(envMap))
	for k, v := range envMap {
		env = append(env, fmt.Sprintf("%s=%s", k, v))
	}
	cmd.Env = env

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return sandbox.RunResult{}, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return sandbox.RunResult{}, err
	}

	if err := cmd.Start(); err != nil {
		return sandbox.RunResult{}, err
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

	// IMPORTANT: Drain pipe readers BEFORE cmd.Wait().
	// Go's exec.Cmd.Wait() closes the pipe read ends. If we call Wait() first,
	// any data still in the kernel pipe buffer is discarded — causing truncation
	// for fast-completing commands. The goroutines will see io.EOF naturally when
	// the child process exits (closing the write end of the pipe).
	consume1 := <-errCh
	consume2 := <-errCh

	waitErr := cmd.Wait()

	result := sandbox.RunResult{
		ExitCode: sandbox.ExitCode(waitErr),
		Status:   sandbox.StatusFrom(ctx, waitErr),
		Warnings: warnings,
	}

	if tr, ok := req.LogSink.(sandbox.TruncationReporter); ok {
		result.StdoutTruncated = tr.StdoutTruncated()
		result.StderrTruncated = tr.StderrTruncated()
	}

	// Propagate context deadline/cancel as status (even if exit code is non-zero)
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


