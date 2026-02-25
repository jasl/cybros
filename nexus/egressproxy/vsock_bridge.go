package egressproxy

import (
	"context"
	"io"
	"log/slog"
	"net"
	"sync"
)

// maxVsockConns limits concurrent connections through the vsock bridge
// to prevent resource exhaustion from a malicious guest VM.
const maxVsockConns = 128

// VsockBridge bridges a Firecracker vsock UDS listener to an egress proxy UDS.
// When a guest connects via vsock CID=2:<port>, Firecracker creates a connection
// on <vsock_uds_path>_<port>. This bridge accepts those connections and forwards
// each one to the egress proxy's UDS socket.
type VsockBridge struct {
	listener  net.Listener
	proxyPath string
	cancel    context.CancelFunc
	done      chan struct{}
	stopOnce  sync.Once
	sem       chan struct{} // connection semaphore (bounded by maxVsockConns)
}

// StartVsockBridge listens on vsockListenPath (UDS) and bridges each
// accepted connection to the egress proxy at proxySocketPath (UDS).
// The bridge stops when the returned VsockBridge is stopped or the context is cancelled.
func StartVsockBridge(ctx context.Context, vsockListenPath, proxySocketPath string) (*VsockBridge, error) {
	listener, err := net.Listen("unix", vsockListenPath)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})

	bridge := &VsockBridge{
		listener:  listener,
		proxyPath: proxySocketPath,
		cancel:    cancel,
		done:      done,
		sem:       make(chan struct{}, maxVsockConns),
	}

	go bridge.serve(ctx)

	return bridge, nil
}

func (b *VsockBridge) serve(ctx context.Context) {
	defer close(b.done)

	var wg sync.WaitGroup
	defer wg.Wait()

	go func() {
		<-ctx.Done()
		b.listener.Close()
	}()

	for {
		conn, err := b.listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			slog.Error("vsock bridge: accept error", "error", err)
			return
		}

		// Enforce connection limit to prevent resource exhaustion.
		select {
		case b.sem <- struct{}{}:
			// acquired
		default:
			slog.Warn("vsock bridge: connection limit reached, rejecting", "max_conns", maxVsockConns)
			conn.Close()
			continue
		}

		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-b.sem }()
			b.handleConn(conn)
		}()
	}
}

func (b *VsockBridge) handleConn(clientConn net.Conn) {
	defer clientConn.Close()

	proxyConn, err := net.Dial("unix", b.proxyPath)
	if err != nil {
		slog.Error("vsock bridge: dial proxy failed", "error", err)
		return
	}
	defer proxyConn.Close()

	// Bidirectional copy: when first direction finishes, close both to unblock the other.
	done := make(chan struct{}, 2)
	go func() { io.Copy(proxyConn, clientConn); done <- struct{}{} }()
	go func() { io.Copy(clientConn, proxyConn); done <- struct{}{} }()
	<-done
	proxyConn.Close()
	clientConn.Close()
	<-done
}

// Stop shuts down the bridge. Safe to call multiple times.
func (b *VsockBridge) Stop() {
	b.stopOnce.Do(func() {
		b.cancel()
		<-b.done
		// Listener is already closed by the serve goroutine.
	})
}
