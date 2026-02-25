package egressproxy

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// ===================================================================
// VsockBridge Security Tests
//
// Security properties tested:
//   VB1. Bridge only connects to designated proxy socket
//   VB2. Bridge stops cleanly and doesn't leak connections
//   VB2b. Connection limit enforced (anti-DoS)
//   VB3. Multiple client connections are isolated
// ===================================================================

// shortSecTempDir creates a temp directory under /tmp to avoid macOS socket path limits.
func shortSecTempDir(t *testing.T) (string, func()) {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "vbs-")
	if err != nil {
		t.Fatalf("create short temp dir: %v", err)
	}
	return dir, func() { os.RemoveAll(dir) }
}

// --- VB1: Only Connects to Designated Proxy ---

func TestSecurity_VsockBridge_OnlyConnectsToDesignatedProxy(t *testing.T) {
	tmpDir, cleanup := shortSecTempDir(t)
	defer cleanup()

	// Create two mock proxies.
	legitimatePath := filepath.Join(tmpDir, "legit.sock")
	decoyPath := filepath.Join(tmpDir, "decoy.sock")

	legitimateListener, err := net.Listen("unix", legitimatePath)
	if err != nil {
		t.Fatal(err)
	}
	defer legitimateListener.Close()

	decoyListener, err := net.Listen("unix", decoyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer decoyListener.Close()

	// Track connections to decoy.
	decoyConnected := make(chan struct{}, 1)
	go func() {
		conn, err := decoyListener.Accept()
		if err != nil {
			return
		}
		conn.Close()
		decoyConnected <- struct{}{}
	}()

	// Start bridge pointing to LEGITIMATE proxy.
	vsockPath := filepath.Join(tmpDir, "v.sock")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	bridge, err := StartVsockBridge(ctx, vsockPath, legitimatePath)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.Stop()

	// Connect through bridge.
	conn, err := net.Dial("unix", vsockPath)
	if err != nil {
		t.Fatal(err)
	}
	conn.Write([]byte("test"))
	conn.Close()

	// Verify decoy was NOT contacted.
	select {
	case <-decoyConnected:
		t.Error("SECURITY: bridge connected to decoy proxy instead of designated one")
	case <-time.After(500 * time.Millisecond):
		// Good — no connection to decoy.
	}
}

// --- VB2: Clean Stop ---

func TestSecurity_VsockBridge_CleanStopNoLeak(t *testing.T) {
	tmpDir, cleanup := shortSecTempDir(t)
	defer cleanup()

	proxyPath := filepath.Join(tmpDir, "p.sock")
	proxyListener, err := net.Listen("unix", proxyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer proxyListener.Close()

	vsockPath := filepath.Join(tmpDir, "v.sock")
	ctx := context.Background()

	bridge, err := StartVsockBridge(ctx, vsockPath, proxyPath)
	if err != nil {
		t.Fatal(err)
	}

	// Stop should not panic or hang.
	done := make(chan struct{})
	go func() {
		bridge.Stop()
		close(done)
	}()

	select {
	case <-done:
		// OK
	case <-time.After(5 * time.Second):
		t.Fatal("SECURITY: bridge.Stop() hung — potential resource leak")
	}

	// Double-stop should be safe.
	bridge.Stop()
}

// --- VB2b: Connection Limit (Anti-DoS) ---

func TestSecurity_VsockBridge_ConnectionLimit(t *testing.T) {
	tmpDir, cleanup := shortSecTempDir(t)
	defer cleanup()

	proxyPath := filepath.Join(tmpDir, "p.sock")
	proxyListener, err := net.Listen("unix", proxyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer proxyListener.Close()

	// Slow echo server — holds connections open.
	go func() {
		for {
			conn, err := proxyListener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				buf := make([]byte, 1024)
				for {
					n, err := conn.Read(buf)
					if err != nil {
						return
					}
					conn.Write(buf[:n])
				}
			}()
		}
	}()

	vsockPath := filepath.Join(tmpDir, "v.sock")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	bridge, err := StartVsockBridge(ctx, vsockPath, proxyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.Stop()

	// Open maxVsockConns connections — should all succeed.
	conns := make([]net.Conn, 0, maxVsockConns)
	for i := 0; i < maxVsockConns; i++ {
		c, err := net.DialTimeout("unix", vsockPath, 2*time.Second)
		if err != nil {
			t.Fatalf("connection %d of %d failed: %v", i, maxVsockConns, err)
		}
		conns = append(conns, c)
	}
	defer func() {
		for _, c := range conns {
			c.Close()
		}
	}()

	// One more connection should be rejected (bridge closes it immediately).
	extra, err := net.DialTimeout("unix", vsockPath, 2*time.Second)
	if err == nil {
		// Connection accepted at OS level, but bridge should close it.
		extra.SetReadDeadline(time.Now().Add(1 * time.Second))
		buf := make([]byte, 1)
		_, readErr := extra.Read(buf)
		if readErr == nil {
			t.Error("SECURITY: connection beyond limit should be rejected or closed")
		}
		extra.Close()
	}
	// err != nil is also acceptable (connection refused).
}

// --- VB3: Multiple Client Isolation ---

func TestSecurity_VsockBridge_MultipleClientsIsolated(t *testing.T) {
	tmpDir, cleanup := shortSecTempDir(t)
	defer cleanup()

	proxyPath := filepath.Join(tmpDir, "p.sock")
	proxyListener, err := net.Listen("unix", proxyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer proxyListener.Close()

	// Echo server on the proxy side.
	go func() {
		for {
			conn, err := proxyListener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				buf := make([]byte, 1024)
				n, _ := conn.Read(buf)
				conn.Write(buf[:n])
			}()
		}
	}()

	vsockPath := filepath.Join(tmpDir, "v.sock")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	bridge, err := StartVsockBridge(ctx, vsockPath, proxyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.Stop()

	// Connect two clients simultaneously.
	conn1, err := net.Dial("unix", vsockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer conn1.Close()

	conn2, err := net.Dial("unix", vsockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer conn2.Close()

	// Send different data from each.
	conn1.Write([]byte("client1"))
	conn2.Write([]byte("client2"))

	// Read responses.
	buf1 := make([]byte, 64)
	conn1.SetReadDeadline(time.Now().Add(2 * time.Second))
	n1, _ := conn1.Read(buf1)

	buf2 := make([]byte, 64)
	conn2.SetReadDeadline(time.Now().Add(2 * time.Second))
	n2, _ := conn2.Read(buf2)

	// Verify each client got its own response (no cross-contamination).
	if string(buf1[:n1]) != "client1" {
		t.Errorf("SECURITY: client1 received %q instead of own data (cross-contamination)", string(buf1[:n1]))
	}
	if string(buf2[:n2]) != "client2" {
		t.Errorf("SECURITY: client2 received %q instead of own data (cross-contamination)", string(buf2[:n2]))
	}
}
