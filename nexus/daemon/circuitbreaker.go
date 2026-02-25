package daemon

import (
	"sync"
	"time"
)

// circuitState represents one of the three states in a circuit breaker.
type circuitState int

const (
	circuitClosed   circuitState = iota // normal operation
	circuitOpen                         // failing, reject requests
	circuitHalfOpen                     // probing with a single request
)

func (s circuitState) String() string {
	switch s {
	case circuitClosed:
		return "closed"
	case circuitOpen:
		return "open"
	case circuitHalfOpen:
		return "half-open"
	default:
		return "unknown"
	}
}

// circuitBreaker implements a simple circuit breaker for the poll loop.
//
// State transitions:
//
//	closed  → (threshold consecutive failures) → open
//	open    → (cooldown elapsed)               → half-open
//	half-open → (probe succeeds)               → closed
//	half-open → (probe fails)                  → open (doubled cooldown)
type circuitBreaker struct {
	mu sync.Mutex

	state           circuitState
	failures        int
	threshold       int
	cooldown        time.Duration
	initialCooldown time.Duration
	maxCooldown     time.Duration
	openedAt        time.Time

	// nowFn allows injecting a clock for testing.
	nowFn func() time.Time
}

// newCircuitBreaker creates a circuit breaker with the given threshold and
// initial cooldown. maxCooldown caps exponential backoff growth.
func newCircuitBreaker(threshold int, cooldown, maxCooldown time.Duration) *circuitBreaker {
	if threshold <= 0 {
		threshold = 1
	}
	if cooldown <= 0 {
		cooldown = time.Second
	}
	if maxCooldown < cooldown {
		maxCooldown = cooldown
	}
	return &circuitBreaker{
		state:           circuitClosed,
		threshold:       threshold,
		cooldown:        cooldown,
		initialCooldown: cooldown,
		maxCooldown:     maxCooldown,
		nowFn:           time.Now,
	}
}

// Allow reports whether a request should be attempted.
// In the open state, it returns false until the cooldown has elapsed,
// then transitions to half-open and returns true for the probe.
func (cb *circuitBreaker) Allow() bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	switch cb.state {
	case circuitClosed:
		return true
	case circuitHalfOpen:
		// Only one probe allowed; subsequent calls while half-open are rejected.
		return false
	case circuitOpen:
		if cb.nowFn().Sub(cb.openedAt) >= cb.cooldown {
			cb.state = circuitHalfOpen
			return true
		}
		return false
	}
	return true
}

// RecordSuccess records a successful request.
// Resets failure count, cooldown, and transitions back to closed.
func (cb *circuitBreaker) RecordSuccess() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	cb.failures = 0
	cb.cooldown = cb.initialCooldown
	cb.state = circuitClosed
}

// RecordFailure records a failed request.
// After threshold consecutive failures, transitions to open.
// In half-open state, a single failure reopens with doubled cooldown.
func (cb *circuitBreaker) RecordFailure() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	cb.failures++

	switch cb.state {
	case circuitClosed:
		if cb.failures >= cb.threshold {
			cb.state = circuitOpen
			cb.openedAt = cb.nowFn()
		}
	case circuitHalfOpen:
		// Probe failed — reopen with exponential backoff.
		cb.state = circuitOpen
		cb.openedAt = cb.nowFn()
		cb.cooldown *= 2
		if cb.cooldown > cb.maxCooldown {
			cb.cooldown = cb.maxCooldown
		}
	}
}

// State returns the current circuit breaker state.
func (cb *circuitBreaker) State() circuitState {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return cb.state
}

// Cooldown returns the current cooldown duration (useful for sleep decisions).
func (cb *circuitBreaker) Cooldown() time.Duration {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return cb.cooldown
}
