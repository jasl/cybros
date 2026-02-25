package daemon

import (
	"testing"
	"time"
)

func TestCircuitBreaker_StartsClosedAndAllows(t *testing.T) {
	t.Parallel()

	cb := newCircuitBreaker(3, 30*time.Second, 5*time.Minute)

	if cb.State() != circuitClosed {
		t.Fatalf("expected closed, got %s", cb.State())
	}
	if !cb.Allow() {
		t.Fatal("expected Allow()=true in closed state")
	}
}

func TestCircuitBreaker_OpensAfterThreshold(t *testing.T) {
	t.Parallel()

	cb := newCircuitBreaker(3, 30*time.Second, 5*time.Minute)

	// Failures below threshold keep circuit closed.
	cb.RecordFailure()
	cb.RecordFailure()
	if cb.State() != circuitClosed {
		t.Fatalf("expected closed after 2 failures, got %s", cb.State())
	}

	// Third failure trips the breaker.
	cb.RecordFailure()
	if cb.State() != circuitOpen {
		t.Fatalf("expected open after 3 failures, got %s", cb.State())
	}
	if cb.Allow() {
		t.Fatal("expected Allow()=false in open state (cooldown not elapsed)")
	}
}

func TestCircuitBreaker_TransitionsToHalfOpen(t *testing.T) {
	t.Parallel()

	now := time.Now()
	cb := newCircuitBreaker(3, 30*time.Second, 5*time.Minute)
	cb.nowFn = func() time.Time { return now }

	// Trip the breaker.
	for i := 0; i < 3; i++ {
		cb.RecordFailure()
	}
	if cb.State() != circuitOpen {
		t.Fatalf("expected open, got %s", cb.State())
	}

	// Still within cooldown — should be rejected.
	now = now.Add(15 * time.Second)
	cb.nowFn = func() time.Time { return now }
	if cb.Allow() {
		t.Fatal("expected Allow()=false before cooldown expires")
	}

	// After cooldown — should transition to half-open and allow one probe.
	now = now.Add(20 * time.Second) // total 35s > 30s cooldown
	cb.nowFn = func() time.Time { return now }
	if !cb.Allow() {
		t.Fatal("expected Allow()=true after cooldown (half-open probe)")
	}
	if cb.State() != circuitHalfOpen {
		t.Fatalf("expected half-open, got %s", cb.State())
	}

	// Second call in half-open should be rejected (only one probe allowed).
	if cb.Allow() {
		t.Fatal("expected Allow()=false for second call in half-open")
	}
}

func TestCircuitBreaker_ProbeSuccessCloses(t *testing.T) {
	t.Parallel()

	now := time.Now()
	cb := newCircuitBreaker(3, 30*time.Second, 5*time.Minute)
	cb.nowFn = func() time.Time { return now }

	// Trip and wait for half-open.
	for i := 0; i < 3; i++ {
		cb.RecordFailure()
	}
	now = now.Add(31 * time.Second)
	cb.nowFn = func() time.Time { return now }
	cb.Allow() // triggers transition to half-open

	// Probe succeeds.
	cb.RecordSuccess()
	if cb.State() != circuitClosed {
		t.Fatalf("expected closed after probe success, got %s", cb.State())
	}
	if !cb.Allow() {
		t.Fatal("expected Allow()=true after recovery")
	}
}

func TestCircuitBreaker_ProbeFailureReopensWithBackoff(t *testing.T) {
	t.Parallel()

	now := time.Now()
	cb := newCircuitBreaker(3, 30*time.Second, 5*time.Minute)
	cb.nowFn = func() time.Time { return now }

	// Trip and wait for half-open.
	for i := 0; i < 3; i++ {
		cb.RecordFailure()
	}
	now = now.Add(31 * time.Second)
	cb.nowFn = func() time.Time { return now }
	cb.Allow() // half-open

	// Probe fails.
	cb.RecordFailure()
	if cb.State() != circuitOpen {
		t.Fatalf("expected open after probe failure, got %s", cb.State())
	}
	if cb.Cooldown() != 60*time.Second {
		t.Fatalf("expected doubled cooldown 60s, got %v", cb.Cooldown())
	}
}

func TestCircuitBreaker_CooldownCappedAtMax(t *testing.T) {
	t.Parallel()

	now := time.Now()
	cb := newCircuitBreaker(1, 2*time.Minute, 5*time.Minute)
	cb.nowFn = func() time.Time { return now }

	// Trip.
	cb.RecordFailure()

	// First backoff: 2m → half-open → fail → 4m
	now = now.Add(3 * time.Minute)
	cb.nowFn = func() time.Time { return now }
	cb.Allow()
	cb.RecordFailure()
	if cb.Cooldown() != 4*time.Minute {
		t.Fatalf("expected 4m, got %v", cb.Cooldown())
	}

	// Second backoff: 4m → half-open → fail → capped at 5m (not 8m)
	now = now.Add(5 * time.Minute)
	cb.nowFn = func() time.Time { return now }
	cb.Allow()
	cb.RecordFailure()
	if cb.Cooldown() != 5*time.Minute {
		t.Fatalf("expected capped 5m, got %v", cb.Cooldown())
	}
}

func TestCircuitBreaker_SuccessResetsFailureCount(t *testing.T) {
	t.Parallel()

	cb := newCircuitBreaker(3, 30*time.Second, 5*time.Minute)

	// Two failures then a success should reset.
	cb.RecordFailure()
	cb.RecordFailure()
	cb.RecordSuccess()

	// Next two failures should not trip (count was reset).
	cb.RecordFailure()
	cb.RecordFailure()
	if cb.State() != circuitClosed {
		t.Fatalf("expected closed after reset, got %s", cb.State())
	}
}

func TestCircuitState_String(t *testing.T) {
	t.Parallel()

	tests := []struct {
		state circuitState
		want  string
	}{
		{circuitClosed, "closed"},
		{circuitOpen, "open"},
		{circuitHalfOpen, "half-open"},
		{circuitState(99), "unknown"},
	}
	for _, tt := range tests {
		if got := tt.state.String(); got != tt.want {
			t.Errorf("State(%d).String() = %q, want %q", tt.state, got, tt.want)
		}
	}
}
