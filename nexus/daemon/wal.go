package daemon

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sync"

	"cybros.ai/nexus/protocol"
)

// walMaxScanSize is the maximum size of a single WAL entry line.
// Must accommodate FinishedRequest with a base64-encoded diff (up to ~1.4MB).
const walMaxScanSize = 2 * 1024 * 1024 // 2 MiB

// walEntry is one JSONL line in the finished WAL.
type walEntry struct {
	Timestamp   string                   `json:"ts"`
	DirectiveID string                   `json:"directive_id"`
	// Token is the directive authentication token, stored for WAL replay.
	// SECURITY: Persisted in plaintext; the WAL file is protected by
	// filesystem permissions (0o600) and directory permissions (0o700).
	// Tokens are short-lived JWTs that expire after lease TTL.
	Token   string                   `json:"token"`
	Request protocol.FinishedRequest `json:"request"`
}

// finishedWAL persists FinishedRequest payloads that failed to POST,
// so they can be replayed on the next startup.
type finishedWAL struct {
	mu   sync.Mutex
	path string
}

func newFinishedWAL(workDir string) (*finishedWAL, error) {
	dir := filepath.Join(workDir, ".nexus")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create WAL directory: %w", err)
	}
	return &finishedWAL{
		path: filepath.Join(dir, "finished.wal"),
	}, nil
}

// Append writes a failed FinishedRequest to the WAL.
func (w *finishedWAL) Append(entry walEntry) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()

	return json.NewEncoder(f).Encode(entry)
}

// Replay reads all entries from the WAL. Corrupt lines are skipped with a warning.
func (w *finishedWAL) Replay() ([]walEntry, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	f, err := os.Open(w.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	var entries []walEntry
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, walMaxScanSize), walMaxScanSize)
	lineNum := 0
	for scanner.Scan() {
		lineNum++
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var e walEntry
		if err := json.Unmarshal(line, &e); err != nil {
			slog.Warn("WAL: skipping corrupt entry", "line", lineNum, "error", err)
			continue
		}
		entries = append(entries, e)
	}
	return entries, scanner.Err()
}

// Truncate removes all entries from the WAL file.
// Returns nil if the file does not exist (nothing to truncate).
func (w *finishedWAL) Truncate() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	err := os.Truncate(w.path, 0)
	if err != nil && os.IsNotExist(err) {
		return nil
	}
	return err
}
