package daemon

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"cybros.ai/nexus/protocol"
)

func testWAL(t *testing.T) *finishedWAL {
	t.Helper()
	dir := t.TempDir()
	w, err := newFinishedWAL(dir)
	if err != nil {
		t.Fatalf("newFinishedWAL: %v", err)
	}
	return w
}

func testEntry(id string, status string) walEntry {
	exitCode := 1
	return walEntry{
		Timestamp:   time.Now().UTC().Format(time.RFC3339Nano),
		DirectiveID: id,
		Token:       "tok-" + id,
		Request: protocol.FinishedRequest{
			ExitCode: &exitCode,
			Status:   status,
		},
	}
}

func TestWAL_AppendAndReplay(t *testing.T) {
	t.Parallel()

	w := testWAL(t)

	if err := w.Append(testEntry("d-1", "failed")); err != nil {
		t.Fatalf("append d-1: %v", err)
	}
	if err := w.Append(testEntry("d-2", "timed_out")); err != nil {
		t.Fatalf("append d-2: %v", err)
	}

	entries, err := w.Replay()
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
	if entries[0].DirectiveID != "d-1" {
		t.Errorf("expected d-1, got %s", entries[0].DirectiveID)
	}
	if entries[1].DirectiveID != "d-2" {
		t.Errorf("expected d-2, got %s", entries[1].DirectiveID)
	}
	if entries[0].Request.Status != "failed" {
		t.Errorf("expected status failed, got %s", entries[0].Request.Status)
	}
}

func TestWAL_ReplayEmpty(t *testing.T) {
	t.Parallel()

	w := testWAL(t)

	entries, err := w.Replay()
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("expected 0 entries, got %d", len(entries))
	}
}

func TestWAL_Truncate(t *testing.T) {
	t.Parallel()

	w := testWAL(t)

	w.Append(testEntry("d-1", "failed"))
	w.Append(testEntry("d-2", "failed"))

	if err := w.Truncate(); err != nil {
		t.Fatalf("truncate: %v", err)
	}

	entries, err := w.Replay()
	if err != nil {
		t.Fatalf("replay after truncate: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("expected 0 entries after truncate, got %d", len(entries))
	}
}

func TestWAL_CorruptLineSkipped(t *testing.T) {
	t.Parallel()

	w := testWAL(t)

	// Write a valid entry, then corrupt data, then another valid entry.
	w.Append(testEntry("d-1", "failed"))

	// Write corrupt line directly
	f, err := os.OpenFile(w.path, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("open WAL: %v", err)
	}
	f.WriteString("this is not json\n")
	f.Close()

	w.Append(testEntry("d-3", "canceled"))

	entries, err := w.Replay()
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 valid entries (corrupt skipped), got %d", len(entries))
	}
	if entries[0].DirectiveID != "d-1" || entries[1].DirectiveID != "d-3" {
		t.Errorf("unexpected entries: %v", entries)
	}
}

func TestWAL_ConcurrentAppend(t *testing.T) {
	t.Parallel()

	w := testWAL(t)

	var wg sync.WaitGroup
	n := 20
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			w.Append(testEntry("d-concurrent", "failed"))
		}(i)
	}
	wg.Wait()

	entries, err := w.Replay()
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if len(entries) != n {
		t.Fatalf("expected %d entries, got %d", n, len(entries))
	}
}

func TestWAL_DirectoryCreated(t *testing.T) {
	t.Parallel()

	dir := filepath.Join(t.TempDir(), "subdir")
	w, err := newFinishedWAL(dir)
	if err != nil {
		t.Fatalf("newFinishedWAL: %v", err)
	}

	// .nexus subdir should be created
	if err := w.Append(testEntry("d-1", "failed")); err != nil {
		t.Fatalf("append: %v", err)
	}

	info, err := os.Stat(filepath.Join(dir, ".nexus"))
	if err != nil {
		t.Fatalf("stat .nexus dir: %v", err)
	}
	if !info.IsDir() {
		t.Error("expected .nexus to be a directory")
	}
}
