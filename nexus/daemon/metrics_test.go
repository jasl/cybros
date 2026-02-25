package daemon

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

func TestNewMetrics_Registration(t *testing.T) {
	t.Parallel()

	reg := prometheus.NewRegistry()
	m := NewMetrics(reg)

	if m.DirectivesTotal == nil {
		t.Fatal("expected DirectivesTotal to be non-nil")
	}
	if m.DirectiveDuration == nil {
		t.Fatal("expected DirectiveDuration to be non-nil")
	}
	if m.DirectivesInFlight == nil {
		t.Fatal("expected DirectivesInFlight to be non-nil")
	}
	if m.PollTotal == nil {
		t.Fatal("expected PollTotal to be non-nil")
	}
	if m.PollErrorsTotal == nil {
		t.Fatal("expected PollErrorsTotal to be non-nil")
	}
	if m.HeartbeatErrorTotal == nil {
		t.Fatal("expected HeartbeatErrorTotal to be non-nil")
	}
	if m.DriverHealthy == nil {
		t.Fatal("expected DriverHealthy to be non-nil")
	}

	// Verify metrics are actually registered by gathering them.
	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	// At minimum, gauge metrics with default 0 should be gatherable.
	found := map[string]bool{}
	for _, f := range families {
		found[f.GetName()] = true
	}
	if !found["nexusd_directives_in_flight"] {
		t.Error("expected nexusd_directives_in_flight in gathered metrics")
	}
	if !found["nexusd_poll_errors_total"] {
		t.Error("expected nexusd_poll_errors_total in gathered metrics")
	}
}

func TestNewMetrics_DoubleRegistration_Panics(t *testing.T) {
	t.Parallel()

	reg := prometheus.NewRegistry()
	NewMetrics(reg)

	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic on double registration")
		}
	}()
	NewMetrics(reg) // should panic
}

func TestMetrics_IncrementCounters(t *testing.T) {
	t.Parallel()

	reg := prometheus.NewRegistry()
	m := NewMetrics(reg)

	m.DirectivesTotal.WithLabelValues("succeeded").Inc()
	m.DirectivesTotal.WithLabelValues("failed").Inc()
	m.DirectivesTotal.WithLabelValues("failed").Inc()

	m.PollTotal.WithLabelValues("ok").Inc()
	m.PollTotal.WithLabelValues("empty").Inc()
	m.PollTotal.WithLabelValues("error").Inc()

	m.PollErrorsTotal.Inc()
	m.HeartbeatErrorTotal.Inc()

	m.DirectivesInFlight.Set(3)
	m.DirectiveDuration.WithLabelValues("host", "host").Observe(1.5)
	m.DriverHealthy.WithLabelValues("host").Set(1)

	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}

	counts := map[string]int{}
	for _, f := range families {
		counts[f.GetName()] = len(f.GetMetric())
	}

	// DirectivesTotal should have 2 label combinations (succeeded, failed)
	if counts["nexusd_directives_total"] != 2 {
		t.Errorf("expected 2 directive status series, got %d", counts["nexusd_directives_total"])
	}
	// PollTotal should have 3 label combinations (ok, empty, error)
	if counts["nexusd_poll_total"] != 3 {
		t.Errorf("expected 3 poll result series, got %d", counts["nexusd_poll_total"])
	}
}
