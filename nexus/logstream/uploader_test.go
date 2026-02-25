package logstream

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"cybros.ai/nexus/client"
	"cybros.ai/nexus/config"
)

type capturedLogChunk struct {
	Stream    string
	Seq       int
	Bytes     string
	Truncated bool
}

func TestUploader_RespectsCombinedMaxBytesAndSeqStartsAtZero(t *testing.T) {
	t.Parallel()

	var (
		mu     sync.Mutex
		chunks []capturedLogChunk
	)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path != "/conduits/v1/directives/d1/log_chunks" {
			w.WriteHeader(http.StatusNotFound)
			return
		}

		var req struct {
			Stream    string `json:"stream"`
			Seq       int    `json:"seq"`
			Bytes     string `json:"bytes"`
			Truncated bool   `json:"truncated"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}

		b, err := base64.StdEncoding.DecodeString(req.Bytes)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}

		mu.Lock()
		chunks = append(chunks, capturedLogChunk{
			Stream:    req.Stream,
			Seq:       req.Seq,
			Bytes:     string(b),
			Truncated: req.Truncated,
		})
		mu.Unlock()

		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)

	cfg := config.Default()
	cfg.ServerURL = srv.URL
	cfg.TerritoryID = "t1"
	cfg.Poll.LongPollTimeout = 2 * time.Second

	cli, err := client.New(cfg)
	if err != nil {
		t.Fatalf("client.New: %v", err)
	}

	u := New(cli, "d1", func() string { return "token" }, 10, 15)
	u.UploadBytes(context.Background(), "stdout", []byte("1234567890ABCDEF")) // 16 bytes, cap 15

	if !u.StdoutTruncated() {
		t.Fatalf("expected stdout truncated to be true")
	}
	if u.StderrTruncated() {
		t.Fatalf("expected stderr truncated to be false")
	}

	mu.Lock()
	defer mu.Unlock()

	if len(chunks) != 2 {
		t.Fatalf("expected 2 chunks, got %d: %#v", len(chunks), chunks)
	}

	if chunks[0].Stream != "stdout" || chunks[0].Seq != 0 || chunks[0].Truncated {
		t.Fatalf("unexpected first chunk: %#v", chunks[0])
	}
	if chunks[0].Bytes != "1234567890" {
		t.Fatalf("unexpected first chunk bytes: %q", chunks[0].Bytes)
	}

	if chunks[1].Stream != "stdout" || chunks[1].Seq != 1 || !chunks[1].Truncated {
		t.Fatalf("unexpected second chunk: %#v", chunks[1])
	}
	if chunks[1].Bytes != "ABCDE" {
		t.Fatalf("unexpected second chunk bytes: %q", chunks[1].Bytes)
	}
}

func TestUploader_CombinedCapAcrossStreams(t *testing.T) {
	t.Parallel()

	var (
		mu     sync.Mutex
		chunks []capturedLogChunk
	)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path != "/conduits/v1/directives/d2/log_chunks" {
			w.WriteHeader(http.StatusNotFound)
			return
		}

		var req struct {
			Stream    string `json:"stream"`
			Seq       int    `json:"seq"`
			Bytes     string `json:"bytes"`
			Truncated bool   `json:"truncated"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}

		b, err := base64.StdEncoding.DecodeString(req.Bytes)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}

		mu.Lock()
		chunks = append(chunks, capturedLogChunk{
			Stream:    req.Stream,
			Seq:       req.Seq,
			Bytes:     string(b),
			Truncated: req.Truncated,
		})
		mu.Unlock()

		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)

	cfg := config.Default()
	cfg.ServerURL = srv.URL
	cfg.TerritoryID = "t1"
	cfg.Poll.LongPollTimeout = 2 * time.Second

	cli, err := client.New(cfg)
	if err != nil {
		t.Fatalf("client.New: %v", err)
	}

	u := New(cli, "d2", func() string { return "token" }, 10, 10)
	u.UploadBytes(context.Background(), "stdout", []byte("12345"))  // 5
	u.UploadBytes(context.Background(), "stderr", []byte("abcdef")) // 6 -> only 5 accepted
	u.UploadBytes(context.Background(), "stdout", []byte("Z"))      // over cap, should not send

	if !u.StdoutTruncated() {
		t.Fatalf("expected stdout truncated to be true after post-cap write")
	}
	if !u.StderrTruncated() {
		t.Fatalf("expected stderr truncated to be true")
	}

	mu.Lock()
	defer mu.Unlock()

	if len(chunks) != 2 {
		t.Fatalf("expected 2 chunks, got %d: %#v", len(chunks), chunks)
	}

	if chunks[0].Stream != "stdout" || chunks[0].Seq != 0 || chunks[0].Truncated || chunks[0].Bytes != "12345" {
		t.Fatalf("unexpected stdout chunk: %#v", chunks[0])
	}
	if chunks[1].Stream != "stderr" || chunks[1].Seq != 0 || !chunks[1].Truncated || chunks[1].Bytes != "abcde" {
		t.Fatalf("unexpected stderr chunk: %#v", chunks[1])
	}
}

func TestUploader_OverflowWritesBeyondMaxToDisk(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)

	cfg := config.Default()
	cfg.ServerURL = srv.URL
	cfg.TerritoryID = "t1"
	cfg.Poll.LongPollTimeout = 2 * time.Second

	cli, err := client.New(cfg)
	if err != nil {
		t.Fatalf("client.New: %v", err)
	}

	overflowDir := t.TempDir()

	u := New(cli, "d3", func() string { return "token" }, 10, 5)
	u.EnableOverflow(overflowDir, 1_048_576)
	u.UploadBytes(context.Background(), "stdout", []byte("1234567890"))

	if !u.StdoutTruncated() {
		t.Fatalf("expected stdout truncated to be true")
	}

	b, err := os.ReadFile(filepath.Join(overflowDir, "stdout.log"))
	if err != nil {
		t.Fatalf("read overflow stdout.log: %v", err)
	}
	if got := string(b); got != "67890" {
		t.Fatalf("unexpected overflow file bytes: %q", got)
	}
}

func TestUploader_OverflowRespectsMaxBytesPerStream(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)

	cfg := config.Default()
	cfg.ServerURL = srv.URL
	cfg.TerritoryID = "t1"
	cfg.Poll.LongPollTimeout = 2 * time.Second

	cli, err := client.New(cfg)
	if err != nil {
		t.Fatalf("client.New: %v", err)
	}

	overflowDir := t.TempDir()

	u := New(cli, "d4", func() string { return "token" }, 64, 1)
	u.EnableOverflow(overflowDir, 3)
	u.UploadBytes(context.Background(), "stdout", []byte("1234567890"))

	b, err := os.ReadFile(filepath.Join(overflowDir, "stdout.log"))
	if err != nil {
		t.Fatalf("read overflow stdout.log: %v", err)
	}
	if !strings.HasPrefix(string(b), "234") {
		t.Fatalf("expected overflow file to start with %q, got %q", "234", string(b))
	}
	if !strings.Contains(string(b), "overflow file reached max_bytes_per_stream=3") {
		t.Fatalf("expected overflow file to include max-bytes notice, got %q", string(b))
	}
}
