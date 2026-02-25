package daemon

import (
	"github.com/prometheus/client_golang/prometheus"
)

// Metrics holds all Prometheus metrics for the daemon.
// Using a struct (not global vars) keeps metrics testable and avoids
// registry conflicts when multiple tests run in parallel.
type Metrics struct {
	DirectivesTotal    *prometheus.CounterVec
	DirectiveDuration  *prometheus.HistogramVec
	DirectivesInFlight prometheus.Gauge

	PollTotal           *prometheus.CounterVec
	PollErrorsTotal     prometheus.Counter
	HeartbeatErrorTotal prometheus.Counter

	DriverHealthy *prometheus.GaugeVec
}

// NewMetrics creates and registers all daemon metrics on the given registry.
func NewMetrics(reg prometheus.Registerer) *Metrics {
	m := &Metrics{
		DirectivesTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "nexusd_directives_total",
			Help: "Total directives processed, by terminal status.",
		}, []string{"status"}),

		DirectiveDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "nexusd_directive_duration_seconds",
			Help:    "Duration of directive execution in seconds.",
			Buckets: prometheus.DefBuckets,
		}, []string{"driver", "profile"}),

		DirectivesInFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "nexusd_directives_in_flight",
			Help: "Number of directives currently executing.",
		}),

		PollTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "nexusd_poll_total",
			Help: "Total poll requests, by result (ok, empty, error).",
		}, []string{"result"}),

		PollErrorsTotal: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "nexusd_poll_errors_total",
			Help: "Total poll errors.",
		}),

		HeartbeatErrorTotal: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "nexusd_heartbeat_errors_total",
			Help: "Total directive heartbeat errors.",
		}),

		DriverHealthy: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "nexusd_driver_healthy",
			Help: "Whether a sandbox driver is healthy (1=yes, 0=no).",
		}, []string{"driver"}),
	}

	reg.MustRegister(
		m.DirectivesTotal,
		m.DirectiveDuration,
		m.DirectivesInFlight,
		m.PollTotal,
		m.PollErrorsTotal,
		m.HeartbeatErrorTotal,
		m.DriverHealthy,
	)

	return m
}
