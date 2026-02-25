package client

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/protocol"
)

// newTestClient creates a Client pointing at the given test server.
func newTestClient(t *testing.T, srv *httptest.Server) *Client {
	t.Helper()
	return &Client{
		baseURL:     srv.URL,
		hc:          srv.Client(),
		territoryID: "test-territory-123",
	}
}

// --- Constructor ---

func TestNew_MinimalConfig(t *testing.T) {
	t.Parallel()

	cfg := config.Default()
	cfg.ServerURL = "http://localhost:3000/"

	cli, err := New(cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Trailing slash should be trimmed.
	if cli.baseURL != "http://localhost:3000" {
		t.Fatalf("expected trimmed baseURL, got %q", cli.baseURL)
	}
}

func TestNew_InvalidTLS(t *testing.T) {
	t.Parallel()

	cfg := config.Default()
	cfg.TLS.CAFile = "/nonexistent/ca.pem"

	_, err := New(cfg)
	if err == nil {
		t.Fatal("expected error for nonexistent CA file")
	}
}

// --- Poll ---

func TestPoll_Success(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("expected POST, got %s", r.Method)
		}
		if r.URL.Path != "/conduits/v1/polls" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if r.Header.Get("X-Nexus-Territory-Id") == "" {
			t.Error("expected X-Nexus-Territory-Id header")
		}

		resp := protocol.PollResponse{
			Directives: []protocol.DirectiveLease{
				{DirectiveID: "d-1", DirectiveToken: "tok-1"},
			},
			LeaseTTLSeconds: 60,
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	out, err := cli.Poll(context.Background(), protocol.PollRequest{
		SupportedSandboxProfiles: []string{"host"},
		MaxDirectivesToClaim:     1,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(out.Directives) != 1 {
		t.Fatalf("expected 1 directive, got %d", len(out.Directives))
	}
	if out.Directives[0].DirectiveID != "d-1" {
		t.Fatalf("expected directive ID d-1, got %s", out.Directives[0].DirectiveID)
	}
}

func TestPoll_EmptyResponse(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(protocol.PollResponse{})
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	out, err := cli.Poll(context.Background(), protocol.PollRequest{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(out.Directives) != 0 {
		t.Fatalf("expected 0 directives, got %d", len(out.Directives))
	}
}

// --- Enroll ---

func TestEnroll_Success(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/conduits/v1/territories/enroll" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}

		var req protocol.EnrollRequest
		json.NewDecoder(r.Body).Decode(&req)
		if req.EnrollToken != "tok-abc" {
			t.Errorf("expected token tok-abc, got %s", req.EnrollToken)
		}

		resp := protocol.EnrollResponse{TerritoryID: "t-new"}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	out, err := cli.Enroll(context.Background(), protocol.EnrollRequest{EnrollToken: "tok-abc"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.TerritoryID != "t-new" {
		t.Fatalf("expected territory ID t-new, got %s", out.TerritoryID)
	}
}

// --- TerritoryHeartbeat ---

func TestTerritoryHeartbeat_Success(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/conduits/v1/territories/heartbeat" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		resp := protocol.TerritoryHeartbeatResponse{OK: true, TerritoryID: "t-1"}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	out, err := cli.TerritoryHeartbeat(context.Background(), protocol.TerritoryHeartbeatRequest{
		NexusVersion: "dev",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !out.OK {
		t.Fatal("expected OK=true")
	}
}

// --- Started ---

func TestStarted_Success(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/conduits/v1/directives/d-1/started" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer jwt-tok" {
			t.Error("expected Bearer jwt-tok Authorization header")
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	err := cli.Started(context.Background(), "d-1", "jwt-tok", protocol.StartedRequest{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// --- Heartbeat ---

func TestHeartbeat_CancelRequested(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/conduits/v1/directives/d-2/heartbeat" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		resp := protocol.HeartbeatResponse{CancelRequested: true, LeaseRenewed: true}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	out, err := cli.Heartbeat(context.Background(), "d-2", "jwt-tok", protocol.HeartbeatRequest{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !out.CancelRequested {
		t.Fatal("expected cancel_requested=true")
	}
	if !out.LeaseRenewed {
		t.Fatal("expected lease_renewed=true")
	}
}

// --- LogChunk ---

func TestLogChunk_Success(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/conduits/v1/directives/d-3/log_chunks" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}

		var req protocol.LogChunkRequest
		json.NewDecoder(r.Body).Decode(&req)
		if req.Stream != "stdout" {
			t.Errorf("expected stream stdout, got %s", req.Stream)
		}
		if req.Seq != 5 {
			t.Errorf("expected seq 5, got %d", req.Seq)
		}

		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	err := cli.LogChunk(context.Background(), "d-3", "jwt-tok", protocol.LogChunkRequest{
		Stream:      "stdout",
		Seq:         5,
		BytesBase64: "aGVsbG8=",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// --- Finished ---

func TestFinished_Success(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/conduits/v1/directives/d-4/finished" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}

		var req protocol.FinishedRequest
		json.NewDecoder(r.Body).Decode(&req)
		if req.Status != "succeeded" {
			t.Errorf("expected status succeeded, got %s", req.Status)
		}

		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	exitCode := 0
	err := cli.Finished(context.Background(), "d-4", "jwt-tok", protocol.FinishedRequest{
		ExitCode: &exitCode,
		Status:   "succeeded",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// --- Error handling ---

func TestPostJSON_HTTPError(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		io.WriteString(w, `{"error":"validation failed"}`)
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	_, err := cli.Poll(context.Background(), protocol.PollRequest{})
	if err == nil {
		t.Fatal("expected error for 422 status")
	}

	httpErr, ok := err.(HTTPError)
	if !ok {
		t.Fatalf("expected HTTPError, got %T", err)
	}
	if httpErr.StatusCode != 422 {
		t.Fatalf("expected status 422, got %d", httpErr.StatusCode)
	}
}

func TestPostJSON_RetryAfter(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "30")
		w.WriteHeader(http.StatusTooManyRequests)
		io.WriteString(w, "rate limited")
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	_, err := cli.Poll(context.Background(), protocol.PollRequest{})
	if err == nil {
		t.Fatal("expected error for 429 status")
	}

	httpErr, ok := err.(HTTPError)
	if !ok {
		t.Fatalf("expected HTTPError, got %T", err)
	}
	if httpErr.StatusCode != 429 {
		t.Fatalf("expected status 429, got %d", httpErr.StatusCode)
	}
	if httpErr.RetryAfter != 30*time.Second {
		t.Fatalf("expected RetryAfter 30s, got %v", httpErr.RetryAfter)
	}
}

func TestPostJSON_ContextCancel(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(5 * time.Second)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	_, err := cli.Poll(ctx, protocol.PollRequest{})
	if err == nil {
		t.Fatal("expected error for canceled context")
	}
}

func TestPostJSON_ServerError(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		io.WriteString(w, "internal server error")
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	err := cli.Started(context.Background(), "d-1", "tok", protocol.StartedRequest{})
	if err == nil {
		t.Fatal("expected error for 500 status")
	}

	httpErr, ok := err.(HTTPError)
	if !ok {
		t.Fatalf("expected HTTPError, got %T", err)
	}
	if httpErr.StatusCode != 500 {
		t.Fatalf("expected status 500, got %d", httpErr.StatusCode)
	}
}

// --- Headers ---

func TestPostJSON_Headers(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Type") != "application/json" {
			t.Error("expected Content-Type application/json")
		}
		if r.Header.Get("X-Nexus-Territory-Id") != "test-territory-123" {
			t.Error("expected X-Nexus-Territory-Id header")
		}
		// No Authorization for poll (no directive token).
		if r.Header.Get("Authorization") != "" {
			t.Error("expected no Authorization header for poll")
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(protocol.PollResponse{})
	}))
	defer srv.Close()

	cli := newTestClient(t, srv)
	_, err := cli.Poll(context.Background(), protocol.PollRequest{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// --- HTTPError ---

func TestHTTPError_Error(t *testing.T) {
	t.Parallel()

	t.Run("without_retry_after", func(t *testing.T) {
		t.Parallel()
		e := HTTPError{StatusCode: 404, Body: "not found"}
		if e.Error() != "HTTP 404: not found" {
			t.Fatalf("unexpected: %s", e.Error())
		}
	})

	t.Run("with_retry_after", func(t *testing.T) {
		t.Parallel()
		e := HTTPError{StatusCode: 429, Body: "rate limited", RetryAfter: 30 * time.Second}
		expected := "HTTP 429 (retry after 30s): rate limited"
		if e.Error() != expected {
			t.Fatalf("expected %q, got %q", expected, e.Error())
		}
	})
}

// --- WithTimeout ---

func TestWithTimeout(t *testing.T) {
	t.Parallel()

	ctx, cancel := WithTimeout(context.Background())
	defer cancel()

	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatal("expected deadline to be set")
	}
	remaining := time.Until(deadline)
	if remaining < 9*time.Second || remaining > 11*time.Second {
		t.Fatalf("expected ~10s timeout, got %v", remaining)
	}
}
