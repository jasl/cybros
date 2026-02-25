package egressproxy

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestAuditLogger_Log(t *testing.T) {
	var buf bytes.Buffer
	logger := NewAuditLogger(&buf, "dir-123")

	logger.Log(AuditEvent{
		DestHost:   "example.com",
		DestPort:   443,
		Decision:   "allow",
		ReasonCode: "OK",
		Method:     "CONNECT",
	})

	line := buf.String()
	if line == "" {
		t.Fatal("expected output, got empty string")
	}

	var got AuditEvent
	if err := json.Unmarshal([]byte(line), &got); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	if got.DirectiveID != "dir-123" {
		t.Errorf("directive_id = %q, want %q", got.DirectiveID, "dir-123")
	}
	if got.DestHost != "example.com" {
		t.Errorf("dest_host = %q, want %q", got.DestHost, "example.com")
	}
	if got.DestPort != 443 {
		t.Errorf("dest_port = %d, want %d", got.DestPort, 443)
	}
	if got.Decision != "allow" {
		t.Errorf("decision = %q, want %q", got.Decision, "allow")
	}
	if got.Timestamp == "" {
		t.Error("timestamp should not be empty")
	}
}

func TestAuditLogger_ConcurrentSafe(t *testing.T) {
	var buf bytes.Buffer
	logger := NewAuditLogger(&buf, "dir-concurrent")

	done := make(chan struct{}, 10)
	for i := 0; i < 10; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			logger.Log(AuditEvent{
				DestHost:   "example.com",
				DestPort:   443,
				Decision:   "allow",
				ReasonCode: "OK",
			})
		}()
	}
	for i := 0; i < 10; i++ {
		<-done
	}

	lines := bytes.Count(buf.Bytes(), []byte("\n"))
	if lines != 10 {
		t.Errorf("expected 10 lines, got %d", lines)
	}
}
