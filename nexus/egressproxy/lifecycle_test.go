package egressproxy

import (
	"bytes"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"cybros.ai/nexus/protocol"
)

func TestStartForDirective_StartsAndStops(t *testing.T) {
	// Use /tmp for short socket paths (macOS 108-char limit)
	socketDir := os.TempDir()
	var auditBuf bytes.Buffer

	cap := &protocol.NetCapabilityV1{Mode: "none"}
	inst, err := StartForDirective(socketDir, "test-123", cap, &auditBuf)
	if err != nil {
		t.Fatalf("StartForDirective: %v", err)
	}

	// Verify socket exists and is connectable
	socketPath := inst.SocketPath()
	for i := 0; i < 50; i++ {
		conn, err := net.DialTimeout("unix", socketPath, 100*time.Millisecond)
		if err == nil {
			conn.Close()
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	conn, err := net.DialTimeout("unix", socketPath, 500*time.Millisecond)
	if err != nil {
		t.Fatalf("could not connect to proxy socket: %v", err)
	}
	conn.Close()

	// Stop should clean up
	inst.Stop()

	if _, err := os.Stat(socketPath); !os.IsNotExist(err) {
		t.Error("socket file should be removed after Stop()")
	}
}

func TestStartForDirective_DoubleStop(t *testing.T) {
	socketDir := os.TempDir()
	var auditBuf bytes.Buffer

	cap := &protocol.NetCapabilityV1{Mode: "none"}
	inst, err := StartForDirective(socketDir, "double-stop", cap, &auditBuf)
	if err != nil {
		t.Fatalf("StartForDirective: %v", err)
	}

	inst.Stop()
	// Second stop should not panic
	inst.Stop()
}

func TestStartForDirective_InvalidPolicy(t *testing.T) {
	socketDir := os.TempDir()
	var auditBuf bytes.Buffer

	cap := &protocol.NetCapabilityV1{
		Mode:  "allowlist",
		Allow: []string{"invalid-entry"},
	}
	_, err := StartForDirective(socketDir, "bad-policy", cap, &auditBuf)
	if err == nil {
		t.Fatal("expected error for invalid allowlist entry")
	}
}

// FIX M5: test that invalid directive IDs are rejected
func TestStartForDirective_InvalidDirectiveID(t *testing.T) {
	socketDir := os.TempDir()
	var auditBuf bytes.Buffer

	cap := &protocol.NetCapabilityV1{Mode: "none"}

	invalidIDs := []string{
		"../etc/passwd",
		"foo/bar",
		"",
		".hidden",
		"hello world",
	}

	for _, id := range invalidIDs {
		_, err := StartForDirective(socketDir, id, cap, &auditBuf)
		if err == nil {
			t.Errorf("directive ID %q should be rejected", id)
		}
	}
}

// FIX M4: test that overly long socket paths are rejected
func TestStartForDirective_SocketPathTooLong(t *testing.T) {
	socketDir := os.TempDir()
	var auditBuf bytes.Buffer

	cap := &protocol.NetCapabilityV1{Mode: "none"}

	// Create a directive ID that makes the socket path exceed 104 chars
	longID := strings.Repeat("a", 200)
	_, err := StartForDirective(socketDir, longID, cap, &auditBuf)
	if err == nil {
		t.Error("expected error for overly long socket path")
	}
}
