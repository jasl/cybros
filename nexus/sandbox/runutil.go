package sandbox

import (
	"context"
	"errors"
	"io"
	"os/exec"
	"syscall"
)

// TruncationReporter is implemented by LogSink implementations that track
// whether stdout/stderr output was truncated due to size limits.
// Used by host-executing drivers to populate RunResult truncation fields.
type TruncationReporter interface {
	StdoutTruncated() bool
	StderrTruncated() bool
}

// StatusFrom derives a human-readable status string from a cmd.Wait() error
// and the context state. Used by host-executing drivers (host, darwin-automation).
func StatusFrom(ctx context.Context, waitErr error) string {
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

// ExitCode extracts the process exit code from a cmd.Wait() error.
// Returns 0 for nil error, the actual exit code for normal exits,
// 128+signal for signal-killed processes, and 1 as fallback.
func ExitCode(waitErr error) int {
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

// DiscardSink is a LogSink that reads and discards all output.
// Useful in tests and dry-run scenarios where log output is not needed.
type DiscardSink struct{}

// Consume reads from r until EOF, discarding all data.
func (d *DiscardSink) Consume(_ context.Context, _ string, r io.Reader) error {
	buf := make([]byte, 4096)
	for {
		_, err := r.Read(buf)
		if err != nil {
			return nil
		}
	}
}
