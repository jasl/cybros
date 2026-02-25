// Package darwinautomation provides a sandbox driver for macOS desktop
// automation directives. It executes commands on the host macOS system
// with access to Shortcuts, AppleScript, and UI automation via osascript.
//
// This driver provides no OS-level isolation (equivalent to the host driver).
// Security is enforced through Policy/Approval/Audit (Phase 2) and macOS TCC
// permissions. Seatbelt (sandbox-exec) profiles are a future enhancement.
package darwinautomation

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"cybros.ai/nexus/sandbox"
)

// Driver implements the sandbox.Driver interface for macOS desktop automation.
type Driver struct{}

// New creates a new darwin-automation driver.
func New() *Driver { return &Driver{} }

// Name returns the driver identifier.
func (d *Driver) Name() string { return "darwin-automation" }

// HealthCheck reports the driver as healthy (no external dependencies required).
// TCC permission status is included in Details for observability but does not
// gate health — not all directives require TCC permissions.
func (d *Driver) HealthCheck(_ context.Context) sandbox.HealthResult {
	details := map[string]string{"driver": "darwin-automation"}

	// Merge TCC permission status into details (informational only).
	for k, v := range checkTCCPermissions() {
		details[k] = v
	}

	return sandbox.HealthResult{
		Healthy: true,
		Details: details,
	}
}

// minimalDarwinEnv returns the minimum set of environment variables inherited
// from the host process. Same allowlist as the host driver plus SSH_AUTH_SOCK
// for potential git/SSH operations triggered by automation scripts.
func minimalDarwinEnv() map[string]string {
	env := map[string]string{}
	for _, key := range []string{
		"PATH", "HOME", "USER", "LOGNAME", "SHELL",
		"TMPDIR", "LANG", "LC_ALL", "SSH_AUTH_SOCK",
	} {
		if v := os.Getenv(key); v != "" {
			env[key] = v
		}
	}
	return env
}

// Run executes a command on the macOS host with process group management
// and concurrent log streaming. The default shell is /bin/zsh (macOS default).
func (d *Driver) Run(ctx context.Context, req sandbox.RunRequest) (sandbox.RunResult, error) {
	if req.Command == "" {
		return sandbox.RunResult{}, errors.New("empty command")
	}
	if req.LogSink == nil {
		return sandbox.RunResult{}, errors.New("LogSink is required")
	}

	shell := req.Shell
	if shell == "" {
		shell = "/bin/zsh"
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

	// Env: start with minimal darwin env, then apply directive-specific overrides.
	envMap := minimalDarwinEnv()
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

	// Stream logs concurrently. Drain pipe readers BEFORE cmd.Wait() to
	// avoid losing buffered data.
	errCh := make(chan error, 2)
	go func() { errCh <- req.LogSink.Consume(ctx, "stdout", stdout) }()
	go func() { errCh <- req.LogSink.Consume(ctx, "stderr", stderr) }()

	consume1 := <-errCh
	consume2 := <-errCh

	waitErr := cmd.Wait()

	result := sandbox.RunResult{
		ExitCode: sandbox.ExitCode(waitErr),
		Status:   sandbox.StatusFrom(ctx, waitErr),
	}

	if tr, ok := req.LogSink.(sandbox.TruncationReporter); ok {
		result.StdoutTruncated = tr.StdoutTruncated()
		result.StderrTruncated = tr.StderrTruncated()
	}

	// Propagate context deadline/cancel as status.
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

