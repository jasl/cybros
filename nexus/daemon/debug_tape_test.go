package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDebugTape_WritesJSONLAndRotates(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "tape.jsonl")

	tape, err := newDebugTape(path, 1)
	if err != nil {
		t.Fatalf("newDebugTape: %v", err)
	}
	t.Cleanup(func() { _ = tape.Close() })

	tape.Record(tapeLine{Event: "first", DirectiveID: "d1", Detail: map[string]any{"msg": strings.Repeat("a", 20)}})
	tape.Record(tapeLine{Event: "second", DirectiveID: "d1", Detail: map[string]any{"msg": strings.Repeat("b", 20)}})

	b1, err := os.ReadFile(path + ".1")
	if err != nil {
		t.Fatalf("read rotated tape: %v", err)
	}
	if len(strings.TrimSpace(string(b1))) == 0 {
		t.Fatalf("expected rotated tape to contain content")
	}

	b0, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read tape: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(b0)), "\n")
	if len(lines) != 1 {
		t.Fatalf("expected exactly 1 line in new tape after rotation, got %d: %q", len(lines), string(b0))
	}

	var parsed tapeLine
	if err := json.Unmarshal([]byte(lines[0]), &parsed); err != nil {
		t.Fatalf("parse JSONL: %v", err)
	}
	if parsed.Event != "second" {
		t.Fatalf("expected last event to be %q, got %q", "second", parsed.Event)
	}
	if parsed.DirectiveID != "d1" {
		t.Fatalf("expected directive_id to be %q, got %q", "d1", parsed.DirectiveID)
	}
}
