package sandbox

import (
	"context"
	"errors"
	"os/exec"
	"testing"
	"time"
)

func TestStatusFrom(t *testing.T) {
	t.Parallel()

	t.Run("nil_error_returns_succeeded", func(t *testing.T) {
		t.Parallel()
		if got := StatusFrom(context.Background(), nil); got != "succeeded" {
			t.Fatalf("got %q, want %q", got, "succeeded")
		}
	})

	t.Run("non_nil_error_returns_failed", func(t *testing.T) {
		t.Parallel()
		if got := StatusFrom(context.Background(), errors.New("exit status 1")); got != "failed" {
			t.Fatalf("got %q, want %q", got, "failed")
		}
	})

	t.Run("deadline_exceeded_returns_timed_out", func(t *testing.T) {
		t.Parallel()
		ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
		defer cancel()
		if got := StatusFrom(ctx, errors.New("signal: killed")); got != "timed_out" {
			t.Fatalf("got %q, want %q", got, "timed_out")
		}
	})

	t.Run("canceled_returns_canceled", func(t *testing.T) {
		t.Parallel()
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if got := StatusFrom(ctx, errors.New("signal: killed")); got != "canceled" {
			t.Fatalf("got %q, want %q", got, "canceled")
		}
	})

	t.Run("nil_error_with_canceled_ctx_returns_succeeded", func(t *testing.T) {
		t.Parallel()
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if got := StatusFrom(ctx, nil); got != "succeeded" {
			t.Fatalf("got %q, want %q", got, "succeeded")
		}
	})
}

func TestExitCode(t *testing.T) {
	t.Parallel()

	t.Run("nil_error_returns_0", func(t *testing.T) {
		t.Parallel()
		if got := ExitCode(nil); got != 0 {
			t.Fatalf("got %d, want 0", got)
		}
	})

	t.Run("exit_42", func(t *testing.T) {
		t.Parallel()
		err := exec.Command("/bin/sh", "-c", "exit 42").Run()
		if got := ExitCode(err); got != 42 {
			t.Fatalf("got %d, want 42", got)
		}
	})

	t.Run("exit_1", func(t *testing.T) {
		t.Parallel()
		err := exec.Command("/bin/sh", "-c", "exit 1").Run()
		if got := ExitCode(err); got != 1 {
			t.Fatalf("got %d, want 1", got)
		}
	})

	t.Run("generic_error_returns_1", func(t *testing.T) {
		t.Parallel()
		if got := ExitCode(errors.New("something went wrong")); got != 1 {
			t.Fatalf("got %d, want 1", got)
		}
	})
}
