package daemon

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"cybros.ai/nexus/client"
	"cybros.ai/nexus/protocol"
	"cybros.ai/nexus/version"
)

// tokenHolder provides thread-safe access to a mutable directive token.
// The heartbeat loop refreshes the token; the log uploader and finished
// call read it concurrently.
type tokenHolder struct {
	mu    sync.RWMutex
	token string
}

func newTokenHolder(initial string) *tokenHolder {
	return &tokenHolder{token: initial}
}

func (h *tokenHolder) Get() string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.token
}

func (h *tokenHolder) Set(t string) {
	if t == "" {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.token = t
}

func (s *Service) runTerritoryHeartbeatLoop(ctx context.Context) {
	hasHeaderAuth := s.cfg.TerritoryID != ""
	hasClientCert := s.cfg.TLS.ClientCertFile != "" && s.cfg.TLS.ClientKeyFile != ""
	if !hasHeaderAuth && !hasClientCert {
		slog.Info("skipping territory heartbeat loop: no territory_id and no mTLS client cert")
		return
	}

	interval := s.cfg.TerritoryHeartbeat.Interval
	if interval <= 0 {
		interval = 30 * time.Second
	}

	send := func() {
		labels := map[string]any{}
		for k, v := range s.cfg.Labels {
			labels[k] = v
		}

		// Run health checks on all registered drivers.
		healthCtx, healthCancel := context.WithTimeout(ctx, 15*time.Second)
		healthResults := s.factory.HealthCheckAll(healthCtx)
		healthCancel()

		// Update driver health metrics
		for drvName, result := range healthResults {
			val := 0.0
			if result.Healthy {
				val = 1.0
			}
			s.metrics.DriverHealthy.WithLabelValues(drvName).Set(val)
		}

		capacity := map[string]any{
			"sandbox_health":     healthResults,
			"supported_profiles": s.factory.SupportedProfiles(),
			"untrusted_driver":   s.factory.UntrustedDriverName(),
		}

		hbCtx, cancel := client.WithTimeout(ctx)
		defer cancel()

		count := int(s.runningCount.Load())
		resp, err := s.cli.TerritoryHeartbeat(hbCtx, protocol.TerritoryHeartbeatRequest{
			NexusVersion:           version.Version,
			RunningDirectivesCount: &count,
			Labels:                 labels,
			Capacity:               capacity,
		})
		if err != nil {
			slog.Warn("territory heartbeat failed", "error", err)
		} else {
			if resp.UpgradeAvailable {
				slog.Info("upgrade available", "latest_version", resp.LatestVersion)
			}
			if resp.MinCompatibleVersion != "" && version.Compare(version.Version, resp.MinCompatibleVersion) < 0 {
				slog.Warn("nexusd version may be incompatible with server",
					"current", version.Version,
					"min_compatible", resp.MinCompatibleVersion,
				)
			}
		}
	}

	send()

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			send()
		}
	}
}

// runHeartbeatLoop sends periodic heartbeats during directive execution.
// It stops when the context is canceled (execution finishes).
// If the server responds with a refreshed token, it updates the shared tokenHolder.
// If the server responds with CancelRequested, it cancels the execution context.
func (s *Service) runHeartbeatLoop(ctx context.Context, directiveID string, facilityID string, profile string, driverName string, token *tokenHolder, cancelRequested *atomic.Bool, cancelExec context.CancelFunc) {
	interval := s.cfg.Heartbeat.Interval
	if interval <= 0 {
		interval = 10 * time.Second
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			hbCtx, hbCancel := client.WithTimeout(ctx)
			resp, err := s.cli.Heartbeat(hbCtx, directiveID, token.Get(), protocol.HeartbeatRequest{
				Progress: map[string]any{"state": "running"},
				Now:      time.Now().UTC().Format(time.RFC3339Nano),
			})
			hbCancel()

			if err != nil {
				s.metrics.HeartbeatErrorTotal.Inc()
				slog.Warn("heartbeat failed", "directive_id", directiveID, "error", err)
				s.recordTape("heartbeat_error", directiveID, protocol.DirectiveSpec{Facility: protocol.FacilitySpec{ID: facilityID}}, driverName, profile, map[string]any{"error": err.Error()})
				continue
			}

			// Refresh token if the server returned a new one
			if resp.DirectiveToken != "" {
				token.Set(resp.DirectiveToken)
			}

			if resp.CancelRequested {
				slog.Info("cancel requested", "directive_id", directiveID)
				s.recordTape("cancel_requested", directiveID, protocol.DirectiveSpec{Facility: protocol.FacilitySpec{ID: facilityID}}, driverName, profile, nil)
				cancelRequested.Store(true)
				cancelExec()
				return
			}
		}
	}
}
