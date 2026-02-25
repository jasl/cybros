package daemon

import (
	"context"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

type readyFunc func() bool

func (f readyFunc) Ready() bool { return f() }

func startTestObsServer(t *testing.T, rc ReadinessChecker) (string, context.CancelFunc) {
	t.Helper()

	reg := prometheus.NewRegistry()
	NewMetrics(reg)

	ctx, cancel := context.WithCancel(context.Background())

	// Grab a free port, close it, pass to the server.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		cancel()
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	go startObservabilityServer(ctx, addr, reg, rc)

	// Wait for server to be ready
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get("http://" + addr + "/healthz")
		if err == nil {
			resp.Body.Close()
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	return "http://" + addr, cancel
}

func TestHealthz(t *testing.T) {
	t.Parallel()

	base, cancel := startTestObsServer(t, readyFunc(func() bool { return true }))
	defer cancel()

	resp, err := http.Get(base + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if string(body) != "ok" {
		t.Fatalf("expected body 'ok', got %q", body)
	}
}

func TestReadyz_Ready(t *testing.T) {
	t.Parallel()

	base, cancel := startTestObsServer(t, readyFunc(func() bool { return true }))
	defer cancel()

	resp, err := http.Get(base + "/readyz")
	if err != nil {
		t.Fatalf("GET /readyz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
}

func TestReadyz_NotReady(t *testing.T) {
	t.Parallel()

	base, cancel := startTestObsServer(t, readyFunc(func() bool { return false }))
	defer cancel()

	resp, err := http.Get(base + "/readyz")
	if err != nil {
		t.Fatalf("GET /readyz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 503 {
		t.Fatalf("expected 503, got %d", resp.StatusCode)
	}
}

func TestReadyz_NilChecker(t *testing.T) {
	t.Parallel()

	base, cancel := startTestObsServer(t, nil)
	defer cancel()

	resp, err := http.Get(base + "/readyz")
	if err != nil {
		t.Fatalf("GET /readyz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 503 {
		t.Fatalf("expected 503 for nil checker, got %d", resp.StatusCode)
	}
}

func TestMetricsEndpoint(t *testing.T) {
	t.Parallel()

	base, cancel := startTestObsServer(t, readyFunc(func() bool { return true }))
	defer cancel()

	resp, err := http.Get(base + "/metrics")
	if err != nil {
		t.Fatalf("GET /metrics: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	body, _ := io.ReadAll(resp.Body)
	s := string(body)

	// Should contain our custom metrics
	if !strings.Contains(s, "nexusd_directives_in_flight") {
		t.Error("expected nexusd_directives_in_flight in metrics output")
	}
	if !strings.Contains(s, "nexusd_poll_errors_total") {
		t.Error("expected nexusd_poll_errors_total in metrics output")
	}
}

func TestObsServer_GracefulShutdown(t *testing.T) {
	t.Parallel()

	base, cancel := startTestObsServer(t, readyFunc(func() bool { return true }))

	// Verify it's running
	resp, err := http.Get(base + "/healthz")
	if err != nil {
		t.Fatalf("server not running: %v", err)
	}
	resp.Body.Close()

	// Cancel context to trigger shutdown
	cancel()
	time.Sleep(100 * time.Millisecond)

	// Server should be down
	client := &http.Client{Timeout: 500 * time.Millisecond}
	_, err = client.Get(base + "/healthz")
	if err == nil {
		t.Fatal("expected error after shutdown")
	}
}
