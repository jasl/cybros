package daemon

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"cybros.ai/nexus/client"
)

func postWithRetry(ctx context.Context, name string, fn func() error) error {
	const maxAttempts = 5

	backoff := 2 * time.Second
	maxBackoff := 60 * time.Second

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if err := fn(); err == nil {
			return nil
		} else {
			lastErr = err
		}

		if ctx.Err() != nil {
			return ctx.Err()
		}

		retryAfter, retryable := retryDelay(lastErr)
		if !retryable {
			return lastErr
		}

		sleep := retryAfter
		if sleep <= 0 {
			sleep = backoff
		}

		slog.Warn("request failed, retrying", "request", name, "attempt", attempt, "max_attempts", maxAttempts, "error", lastErr)

		if !sleepCtx(ctx, sleep) {
			return ctx.Err()
		}

		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
	return lastErr
}

func retryDelay(err error) (time.Duration, bool) {
	if err == nil {
		return 0, false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return 0, false
	}

	var httpErr client.HTTPError
	if errors.As(err, &httpErr) {
		ra := httpErr.RetryAfter
		if ra > maxRetryAfter {
			ra = maxRetryAfter
		}
		if httpErr.StatusCode == 429 {
			return ra, true
		}
		if httpErr.StatusCode >= 500 && httpErr.StatusCode <= 599 {
			return ra, true
		}
		return 0, false
	}

	// Treat non-HTTP errors as retryable (network/transient) in Phase 0/0.5.
	return 0, true
}

// sleepCtx sleeps for the given duration but returns immediately (false)
// if the context is canceled.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	select {
	case <-ctx.Done():
		timer.Stop()
		return false
	case <-timer.C:
		return true
	}
}

// cappedDuration converts server-supplied RetryAfterSeconds to a Duration,
// capping it at maxRetryAfter to prevent excessively long waits.
func cappedDuration(seconds int) time.Duration {
	if seconds <= 0 {
		return 0
	}
	d := time.Duration(seconds) * time.Second
	if d > maxRetryAfter {
		d = maxRetryAfter
	}
	return d
}
