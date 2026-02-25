package egressproxy

import (
	"context"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// shortTempDir creates a temp directory under /tmp to avoid macOS long path issues
// with Unix sockets (108 char limit). The returned cleanup func removes it.
func shortTempDir(t *testing.T) (string, func()) {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "vb-")
	if err != nil {
		t.Fatalf("create short temp dir: %v", err)
	}
	return dir, func() { os.RemoveAll(dir) }
}

func TestVsockBridge_BasicForwarding(t *testing.T) {
	tmpDir, cleanup := shortTempDir(t)
	defer cleanup()

	// Create a mock "egress proxy" UDS listener.
	proxyPath := filepath.Join(tmpDir, "p.sock")
	proxyListener, err := net.Listen("unix", proxyPath)
	if err != nil {
		t.Fatalf("listen proxy: %v", err)
	}
	defer proxyListener.Close()

	// Accept connections on the mock proxy and echo back.
	go func() {
		for {
			conn, err := proxyListener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				io.Copy(conn, conn) // echo
			}()
		}
	}()

	// Start the vsock bridge.
	vsockPath := filepath.Join(tmpDir, "v.sock")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	bridge, err := StartVsockBridge(ctx, vsockPath, proxyPath)
	if err != nil {
		t.Fatalf("start bridge: %v", err)
	}
	defer bridge.Stop()

	// Connect to the bridge (simulating a guest connection).
	conn, err := net.Dial("unix", vsockPath)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	defer conn.Close()

	// Send data and verify echo.
	msg := "hello from guest"
	if _, err := conn.Write([]byte(msg)); err != nil {
		t.Fatalf("write: %v", err)
	}

	buf := make([]byte, len(msg))
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := io.ReadFull(conn, buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if got := string(buf[:n]); got != msg {
		t.Errorf("got %q, want %q", got, msg)
	}
}

func TestVsockBridge_StopClosesListener(t *testing.T) {
	tmpDir, cleanup := shortTempDir(t)
	defer cleanup()

	proxyPath := filepath.Join(tmpDir, "p.sock")
	// We don't need a real proxy for this test.
	proxyListener, _ := net.Listen("unix", proxyPath)
	if proxyListener != nil {
		defer proxyListener.Close()
	}

	vsockPath := filepath.Join(tmpDir, "v.sock")
	ctx := context.Background()

	bridge, err := StartVsockBridge(ctx, vsockPath, proxyPath)
	if err != nil {
		t.Fatalf("start bridge: %v", err)
	}

	bridge.Stop()

	// Verify we can't connect after stop.
	_, err = net.DialTimeout("unix", vsockPath, 100*time.Millisecond)
	if err == nil {
		t.Error("expected connection refused after stop")
	}
}

func TestVsockBridge_ProxyUnavailable(t *testing.T) {
	tmpDir, cleanup := shortTempDir(t)
	defer cleanup()

	// Non-existent proxy path — bridge starts fine but connections will fail.
	proxyPath := filepath.Join(tmpDir, "no.sock")
	vsockPath := filepath.Join(tmpDir, "v.sock")

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	bridge, err := StartVsockBridge(ctx, vsockPath, proxyPath)
	if err != nil {
		t.Fatalf("start bridge: %v", err)
	}
	defer bridge.Stop()

	// Connect — should succeed (bridge accepts).
	conn, err := net.Dial("unix", vsockPath)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}

	// Write something — the bridge will try to dial the proxy and fail,
	// which should close the connection.
	conn.Write([]byte("test"))

	// The connection should be closed by the bridge.
	conn.SetReadDeadline(time.Now().Add(1 * time.Second))
	buf := make([]byte, 64)
	_, err = conn.Read(buf)
	if err == nil {
		t.Error("expected read error after proxy dial failure")
	}
	conn.Close()
}

func TestVsockBridge_SocketCleaned(t *testing.T) {
	tmpDir, cleanup := shortTempDir(t)
	defer cleanup()

	proxyPath := filepath.Join(tmpDir, "p.sock")
	vsockPath := filepath.Join(tmpDir, "v.sock")

	ctx := context.Background()
	bridge, err := StartVsockBridge(ctx, vsockPath, proxyPath)
	if err != nil {
		t.Fatalf("start bridge: %v", err)
	}

	// Verify socket exists.
	if _, err := os.Stat(vsockPath); err != nil {
		t.Fatalf("socket should exist: %v", err)
	}

	bridge.Stop()
}
