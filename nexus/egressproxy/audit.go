package egressproxy

import (
	"encoding/json"
	"io"
	"sync"
	"time"
)

// AuditEvent records a single egress connection decision.
type AuditEvent struct {
	Timestamp   string `json:"ts"`
	DirectiveID string `json:"directive_id"`
	DestHost    string `json:"dest_host"`
	DestPort    int    `json:"dest_port"`
	ResolvedIP  string `json:"resolved_ip,omitempty"`
	Decision    string `json:"decision"` // "allow" or "deny"
	ReasonCode  string `json:"reason_code"`
	Method      string `json:"method,omitempty"` // "CONNECT" or "HTTP"
}

// AuditLogger writes audit events as JSONL to a writer.
// It is safe for concurrent use.
type AuditLogger struct {
	mu          sync.Mutex
	w           io.Writer
	directiveID string
}

// NewAuditLogger creates an AuditLogger that writes to w.
func NewAuditLogger(w io.Writer, directiveID string) *AuditLogger {
	return &AuditLogger{w: w, directiveID: directiveID}
}

// Log writes an audit event. It fills in the timestamp and directive ID.
// Errors are silently ignored (best-effort audit).
func (a *AuditLogger) Log(event AuditEvent) {
	event.Timestamp = time.Now().UTC().Format(time.RFC3339Nano)
	event.DirectiveID = a.directiveID

	b, err := json.Marshal(event)
	if err != nil {
		return
	}
	b = append(b, '\n')

	a.mu.Lock()
	defer a.mu.Unlock()
	_, _ = a.w.Write(b)
}
