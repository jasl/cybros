package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"cybros.ai/nexus/client"
	"cybros.ai/nexus/config"
	"cybros.ai/nexus/protocol"
	"cybros.ai/nexus/sandbox"
	"cybros.ai/nexus/version"

	"github.com/prometheus/client_golang/prometheus"
)

// maxRetryAfter caps the server-supplied RetryAfterSeconds to prevent
// a malicious or buggy server from causing excessively long sleeps.
const maxRetryAfter = 5 * time.Minute

type Service struct {
	cfg     config.Config
	cli     *client.Client
	factory *sandbox.DriverFactory
	tape    *debugTape

	metrics *Metrics
	reg     *prometheus.Registry
	wal     *finishedWAL
	cb      *circuitBreaker

	// runningCount tracks the number of currently executing directives.
	runningCount atomic.Int32
}

func New(cfg config.Config) (*Service, error) {
	cli, err := client.New(cfg)
	if err != nil {
		return nil, err
	}

	factory, err := newDriverFactory(cfg)
	if err != nil {
		return nil, err
	}

	var tape *debugTape
	if cfg.DebugTape.Enabled {
		tape, err = newDebugTape(cfg.DebugTape.Path, cfg.DebugTape.MaxBytes)
		if err != nil {
			return nil, err
		}
	}

	reg := prometheus.NewRegistry()
	reg.MustRegister(prometheus.NewProcessCollector(prometheus.ProcessCollectorOpts{}))
	reg.MustRegister(prometheus.NewGoCollector())
	metrics := NewMetrics(reg)

	wal, err := newFinishedWAL(cfg.WorkDir)
	if err != nil {
		return nil, fmt.Errorf("init finished WAL: %w", err)
	}

	return &Service{
		cfg:     cfg,
		cli:     cli,
		factory: factory,
		tape:    tape,
		metrics: metrics,
		reg:     reg,
		wal:     wal,
		cb:      newCircuitBreaker(5, 30*time.Second, 5*time.Minute),
	}, nil
}

// Ready reports whether at least one sandbox driver is healthy.
// Implements ReadinessChecker for the observability server.
func (s *Service) Ready() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, result := range s.factory.HealthCheckAll(ctx) {
		if result.Healthy {
			return true
		}
	}
	return false
}

// rejectDirective reports a directive as started+finished(failed) without executing it.
// Used for early rejection (e.g., insufficient disk space, driver unhealthy, invalid facility).
func (s *Service) rejectDirective(ctx context.Context, directiveID string, token *tokenHolder, spec protocol.DirectiveSpec, startTime time.Time, status, reason string) error {
	startReq := protocol.StartedRequest{
		SandboxVersion: "nexusd",
		NexusVersion:   version.Version,
		StartedAt:      time.Now().UTC().Format(time.RFC3339Nano),
	}
	if err := postWithRetry(ctx, "started", func() error {
		reqCtx, c := client.WithTimeout(ctx)
		defer c()
		return s.cli.Started(reqCtx, directiveID, token.Get(), startReq)
	}); err != nil {
		return fmt.Errorf("reject %s: started post failed: %w", reason, err)
	}
	exitCode := 1
	finishReq := protocol.FinishedRequest{
		ExitCode:          &exitCode,
		Status:            status,
		ArtifactsManifest: map[string]any{},
		FinishedAt:        time.Now().UTC().Format(time.RFC3339Nano),
	}
	if postErr := postWithRetry(ctx, "finished", func() error {
		reqCtx, c := client.WithTimeout(ctx)
		defer c()
		return s.cli.Finished(reqCtx, directiveID, token.Get(), finishReq)
	}); postErr != nil {
		if walErr := s.wal.Append(walEntry{
			Timestamp: time.Now().UTC().Format(time.RFC3339Nano), DirectiveID: directiveID,
			Token: token.Get(), Request: finishReq,
		}); walErr != nil {
			slog.Error("WAL append failed", "directive_id", directiveID, "error", walErr)
		}
	}
	s.metrics.DirectivesTotal.WithLabelValues(status).Inc()
	s.metrics.DirectiveDuration.WithLabelValues("", spec.SandboxProfile).Observe(time.Since(startTime).Seconds())
	return nil
}

func (s *Service) Serve(ctx context.Context) error {
	slog.Info("nexusd starting",
		"version", version.Version,
		"commit", version.Commit,
		"build_date", version.BuildDate,
		"territory_id", s.cfg.TerritoryID,
		"server", s.cfg.ServerURL,
		"profiles", s.factory.SupportedProfiles(),
	)

	if s.tape != nil {
		defer func() { _ = s.tape.Close() }()
	}

	if err := os.MkdirAll(s.cfg.WorkDir, 0o755); err != nil {
		return err
	}

	s.replayWAL(ctx)

	go s.runTerritoryHeartbeatLoop(ctx)

	if s.cfg.Observability.Enabled {
		go startObservabilityServer(ctx, s.cfg.Observability.ListenAddr, s.reg, s)
	}

	// Worker pool for concurrent directive execution
	maxWorkers := s.cfg.Poll.MaxDirectivesToClaim
	if maxWorkers <= 0 {
		maxWorkers = 1
	}
	sem := make(chan struct{}, maxWorkers)
	var wg sync.WaitGroup

	shutdown := func() error {
		inFlight := s.runningCount.Load()
		slog.Info("shutting down", "in_flight", inFlight, "timeout", s.cfg.ShutdownTimeout)

		if s.cfg.ShutdownTimeout <= 0 {
			wg.Wait()
			return ctx.Err()
		}

		done := make(chan struct{})
		go func() {
			wg.Wait()
			close(done)
		}()

		select {
		case <-done:
			slog.Info("all directives finished")
		case <-time.After(s.cfg.ShutdownTimeout):
			slog.Warn("shutdown timeout exceeded, exiting with directives still running",
				"remaining", s.runningCount.Load(),
				"timeout", s.cfg.ShutdownTimeout,
			)
		}
		return ctx.Err()
	}

	for {
		select {
		case <-ctx.Done():
			return shutdown()
		default:
		}

		if !s.cb.Allow() {
			slog.Warn("circuit breaker open, skipping poll", "cooldown", s.cb.Cooldown())
			if !sleepCtx(ctx, s.cb.Cooldown()) {
				return shutdown()
			}
			continue
		}

		resp, err := s.cli.Poll(ctx, protocol.PollRequest{
			SupportedSandboxProfiles: s.factory.SupportedProfiles(),
			MaxDirectivesToClaim:     s.cfg.Poll.MaxDirectivesToClaim,
		})
		if err != nil {
			s.cb.RecordFailure()
			s.metrics.PollTotal.WithLabelValues("error").Inc()
			s.metrics.PollErrorsTotal.Inc()
			slog.Error("poll failed", "error", err)
			if !sleepCtx(ctx, s.cfg.Poll.RetryBackoff) {
				return shutdown()
			}
			continue
		}

		s.cb.RecordSuccess()

		if len(resp.Directives) == 0 {
			s.metrics.PollTotal.WithLabelValues("empty").Inc()
			sleep := s.cfg.Poll.RetryBackoff
			if resp.RetryAfterSeconds > 0 {
				sleep = cappedDuration(resp.RetryAfterSeconds)
			}
			if !sleepCtx(ctx, sleep) {
				return shutdown()
			}
			continue
		}

		s.metrics.PollTotal.WithLabelValues("ok").Inc()
		for _, lease := range resp.Directives {
			lease := lease // capture for goroutine

			// Acquire worker slot (blocks if all workers are busy)
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				return shutdown()
			}

			wg.Add(1)
			s.runningCount.Add(1)
			s.metrics.DirectivesInFlight.Inc()
			go func() {
				defer wg.Done()
				defer s.runningCount.Add(-1)
				defer s.metrics.DirectivesInFlight.Dec()
				defer func() { <-sem }()
				if err := s.handleDirective(ctx, lease); err != nil {
					slog.Error("directive failed", "directive_id", lease.DirectiveID, "error", err)
				}
			}()
		}
	}
}

// replayWAL attempts to re-post any FinishedRequest entries that were
// persisted from a previous run because the server was unreachable.
func (s *Service) replayWAL(ctx context.Context) {
	entries, err := s.wal.Replay()
	if err != nil {
		slog.Error("WAL replay read failed", "error", err)
		return
	}
	if len(entries) == 0 {
		return
	}

	slog.Info("replaying WAL entries", "count", len(entries))
	allOK := true
	for _, e := range entries {
		if ctx.Err() != nil {
			return
		}
		if postErr := postWithRetry(ctx, "wal-replay", func() error {
			reqCtx, cancel := client.WithTimeout(ctx)
			defer cancel()
			return s.cli.Finished(reqCtx, e.DirectiveID, e.Token, e.Request)
		}); postErr != nil {
			slog.Error("WAL replay failed for directive", "directive_id", e.DirectiveID, "error", postErr)
			allOK = false
		}
	}
	if allOK {
		if err := s.wal.Truncate(); err != nil {
			slog.Error("WAL truncate failed", "error", err)
		} else {
			slog.Info("WAL replay complete, truncated")
		}
	}
}
