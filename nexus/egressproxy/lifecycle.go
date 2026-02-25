package egressproxy

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sync"

	"cybros.ai/nexus/protocol"
)

// validDirectiveIDRe matches safe directive IDs for filesystem use.
var validDirectiveIDRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)

// maxSocketPathLen is the conservative Unix domain socket path limit.
const maxSocketPathLen = 104

// Instance represents a running per-directive proxy instance.
type Instance struct {
	socketPath string
	proxyURL   string
	cancel     context.CancelFunc
	done       chan struct{}
	stopOnce   sync.Once
}

// StartForDirective creates and starts an egress proxy for a single directive.
// The proxy listens on a UDS at <socketDir>/<directiveID>.sock.
// The returned Instance must be stopped via Stop() when the directive completes.
func StartForDirective(
	socketDir string,
	directiveID string,
	cap *protocol.NetCapabilityV1,
	auditWriter io.Writer,
) (*Instance, error) {
	// FIX M5: validate directiveID to prevent path traversal
	if !validDirectiveIDRe.MatchString(directiveID) {
		return nil, fmt.Errorf("invalid directive ID: %q", directiveID)
	}

	if err := os.MkdirAll(socketDir, 0o700); err != nil {
		return nil, fmt.Errorf("create socket dir: %w", err)
	}

	socketPath := filepath.Join(socketDir, directiveID+".sock")

	// FIX M4: validate socket path length (Unix domain socket limit)
	if len(socketPath) > maxSocketPathLen {
		return nil, fmt.Errorf("socket path too long (%d > %d chars): %s",
			len(socketPath), maxSocketPathLen, socketPath)
	}

	// Remove stale socket from previous run
	os.Remove(socketPath)

	policy, err := NewPolicy(cap)
	if err != nil {
		return nil, fmt.Errorf("create policy: %w", err)
	}

	audit := NewAuditLogger(auditWriter, directiveID)

	proxy, err := New(socketPath, policy, audit)
	if err != nil {
		return nil, fmt.Errorf("create proxy: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})

	go func() {
		defer close(done)
		if err := proxy.Serve(ctx); err != nil {
			// FIX M6: actually log the error (not propagated; shouldn't crash directive)
			slog.Error("egress proxy serve failed", "directive_id", directiveID, "error", err)
		}
	}()

	return &Instance{
		socketPath: socketPath,
		cancel:     cancel,
		done:       done,
	}, nil
}

// StartForDirectiveTCP creates and starts an egress proxy for a single directive
// on a TCP listener bound to 127.0.0.1:0. This is used by the trusted container
// driver (soft constraint via HTTP_PROXY/HTTPS_PROXY).
func StartForDirectiveTCP(
	directiveID string,
	cap *protocol.NetCapabilityV1,
	auditWriter io.Writer,
) (*Instance, error) {
	// Keep directive ID validation consistent (also used in audit logs).
	if !validDirectiveIDRe.MatchString(directiveID) {
		return nil, fmt.Errorf("invalid directive ID: %q", directiveID)
	}

	policy, err := NewPolicy(cap)
	if err != nil {
		return nil, fmt.Errorf("create policy: %w", err)
	}

	audit := NewAuditLogger(auditWriter, directiveID)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("listen on 127.0.0.1:0: %w", err)
	}

	proxy := NewFromListener(listener, policy, audit)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})

	go func() {
		defer close(done)
		if err := proxy.Serve(ctx); err != nil {
			slog.Error("egress proxy serve failed", "directive_id", directiveID, "error", err)
		}
	}()

	return &Instance{
		proxyURL: "http://" + listener.Addr().String(),
		cancel:   cancel,
		done:     done,
	}, nil
}

// SocketPath returns the UDS path this proxy is listening on.
func (i *Instance) SocketPath() string {
	return i.socketPath
}

// ProxyURL returns the HTTP proxy URL (TCP mode). Empty for UDS instances.
func (i *Instance) ProxyURL() string {
	return i.proxyURL
}

// Stop shuts down the proxy and removes the socket file.
// Safe to call multiple times (idempotent via sync.Once).
func (i *Instance) Stop() {
	i.stopOnce.Do(func() {
		i.cancel()
		<-i.done
		if i.socketPath != "" {
			os.Remove(i.socketPath)
		}
	})
}
