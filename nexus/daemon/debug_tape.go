package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type tapeLine struct {
	Ts          string `json:"ts"`
	DirectiveID string `json:"directive_id,omitempty"`
	FacilityID  string `json:"facility_id,omitempty"`
	Profile     string `json:"profile,omitempty"`
	Driver      string `json:"driver,omitempty"`
	Event       string `json:"event"`
	Detail      any    `json:"detail,omitempty"`
}

type debugTape struct {
	path     string
	maxBytes int64

	mu    sync.Mutex
	file  *os.File
	bytes int64
}

func newDebugTape(path string, maxBytes int64) (*debugTape, error) {
	if path == "" {
		return nil, errors.New("debug tape path is required")
	}
	if maxBytes <= 0 {
		return nil, errors.New("debug tape max_bytes must be >= 1")
	}

	dir := filepath.Dir(path)
	if dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("create debug tape dir: %w", err)
		}
	}

	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open debug tape: %w", err)
	}

	var size int64
	if fi, statErr := f.Stat(); statErr == nil {
		size = fi.Size()
	}

	t := &debugTape{
		path:     path,
		maxBytes: maxBytes,
		file:     f,
		bytes:    size,
	}

	if t.bytes > t.maxBytes {
		if err := t.rotateLocked(); err != nil {
			_ = f.Close()
			return nil, err
		}
	}

	return t, nil
}

func (t *debugTape) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.file == nil {
		return nil
	}
	err := t.file.Close()
	t.file = nil
	return err
}

func (t *debugTape) Record(line tapeLine) {
	if line.Event == "" {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	if t.file == nil {
		return
	}

	if line.Ts == "" {
		line.Ts = time.Now().UTC().Format(time.RFC3339Nano)
	}

	b, err := json.Marshal(line)
	if err != nil {
		return
	}
	b = append(b, '\n')

	if t.bytes+int64(len(b)) > t.maxBytes {
		if err := t.rotateLocked(); err != nil {
			return
		}
	}

	if _, err := t.file.Write(b); err != nil {
		return
	}
	t.bytes += int64(len(b))
}

func (t *debugTape) rotateLocked() error {
	if t.file != nil {
		_ = t.file.Close()
		t.file = nil
	}

	_ = os.Remove(t.path + ".1")
	if err := os.Rename(t.path, t.path+".1"); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("rotate debug tape: %w", err)
	}

	f, err := os.OpenFile(t.path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("open debug tape after rotation: %w", err)
	}

	t.file = f
	t.bytes = 0
	return nil
}
