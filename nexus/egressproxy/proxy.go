package egressproxy

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Proxy is an egress HTTP/CONNECT proxy that enforces network policy.
// It listens on a listener (UDS in Phase 1) and checks every connection against
// an allowlist before forwarding.
type Proxy struct {
	policy   *Policy
	audit    *AuditLogger
	listener net.Listener
	server   *http.Server
	wg       sync.WaitGroup
}

// New creates a proxy that listens on the given UDS path.
func New(socketPath string, policy *Policy, audit *AuditLogger) (*Proxy, error) {
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", socketPath, err)
	}
	return NewFromListener(listener, policy, audit), nil
}

// NewFromListener creates a proxy for an already-created listener (UDS or TCP).
func NewFromListener(listener net.Listener, policy *Policy, audit *AuditLogger) *Proxy {
	p := &Proxy{
		policy:   policy,
		audit:    audit,
		listener: listener,
	}
	p.server = &http.Server{
		Handler:           p,
		ReadHeaderTimeout: 30 * time.Second,
	}
	return p
}

// Serve starts the proxy. Blocks until the context is canceled.
// It supports HTTP proxy (absolute-form + CONNECT) and SOCKS5 on the same listener.
func (p *Proxy) Serve(ctx context.Context) error {
	httpListener := newConnQueueListener(p.listener.Addr())
	httpErrCh := make(chan error, 1)
	go func() { httpErrCh <- p.server.Serve(httpListener) }()

	go func() {
		<-ctx.Done()
		p.listener.Close()
		httpListener.Close()
	}()

	var acceptErr error
	for {
		conn, err := p.listener.Accept()
		if err != nil {
			acceptErr = err
			break
		}

		p.wg.Add(1)
		go func() {
			defer p.wg.Done()
			p.routeConn(ctx, conn, httpListener)
		}()
	}

	httpListener.Close()

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	_ = p.server.Shutdown(shutdownCtx)
	cancel()

	httpErr := <-httpErrCh
	p.wg.Wait()

	if ctx.Err() != nil {
		return nil
	}
	if errors.Is(acceptErr, net.ErrClosed) {
		acceptErr = nil
	}
	if errors.Is(httpErr, http.ErrServerClosed) {
		httpErr = nil
	}
	if acceptErr != nil {
		return acceptErr
	}
	if httpErr != nil {
		return httpErr
	}
	return nil
}

func (p *Proxy) routeConn(ctx context.Context, conn net.Conn, httpListener *connQueueListener) {
	br := bufio.NewReader(conn)

	// First-byte peek should never stall the accept loop.
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	b, err := br.Peek(1)
	if err != nil {
		conn.Close()
		return
	}
	_ = conn.SetReadDeadline(time.Time{})

	// SOCKS5: version byte 0x05
	if b[0] == socks5Version {
		p.handleSOCKS5(conn, br)
		return
	}

	// Default: HTTP proxy (CONNECT/HTTP) via http.Server
	if !httpListener.Enqueue(ctx, &preReadConn{Conn: conn, r: br}) {
		conn.Close()
	}
}

type preReadConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *preReadConn) Read(p []byte) (int, error) { return c.r.Read(p) }

type connQueueListener struct {
	addr net.Addr

	ch        chan net.Conn
	closed    chan struct{}
	closeOnce sync.Once
}

func newConnQueueListener(addr net.Addr) *connQueueListener {
	return &connQueueListener{
		addr:   addr,
		ch:     make(chan net.Conn, 128),
		closed: make(chan struct{}),
	}
}

func (l *connQueueListener) Enqueue(ctx context.Context, conn net.Conn) bool {
	select {
	case <-ctx.Done():
		return false
	case <-l.closed:
		return false
	case l.ch <- conn:
		return true
	}
}

func (l *connQueueListener) Accept() (net.Conn, error) {
	select {
	case conn, ok := <-l.ch:
		if !ok {
			return nil, net.ErrClosed
		}
		return conn, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *connQueueListener) Close() error {
	l.closeOnce.Do(func() {
		close(l.closed)
		// Do NOT close l.ch to avoid a send-on-closed-channel panic
		// from a concurrent Enqueue call. The closed channel signals
		// both Accept and Enqueue to stop; GC reclaims l.ch.
	})
	return nil
}

func (l *connQueueListener) Addr() net.Addr { return l.addr }

// SocketPath returns the path the proxy is listening on (UDS only).
func (p *Proxy) SocketPath() string {
	if ua, ok := p.listener.Addr().(*net.UnixAddr); ok {
		return ua.Name
	}
	return ""
}

// ServeHTTP dispatches CONNECT vs regular HTTP requests.
func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		p.handleConnect(w, r)
	} else {
		p.handleHTTP(w, r)
	}
}

func (p *Proxy) handleConnect(w http.ResponseWriter, r *http.Request) {
	destHost, destPort, err := splitHostPort(r.Host)
	if err != nil {
		p.audit.Log(AuditEvent{
			DestHost:   strings.TrimSpace(r.Host),
			DestPort:   0,
			Decision:   "deny",
			ReasonCode: "INVALID_DESTINATION",
			Method:     "CONNECT",
		})
		http.Error(w, "invalid host:port", http.StatusBadRequest)
		return
	}

	// Check allowlist policy
	result := p.policy.Check(destHost, destPort)
	if !result.Allowed {
		p.audit.Log(AuditEvent{
			DestHost:   destHost,
			DestPort:   destPort,
			Decision:   "deny",
			ReasonCode: result.ReasonCode,
			Method:     "CONNECT",
		})
		http.Error(w, fmt.Sprintf("egress denied: %s", result.ReasonCode), http.StatusForbidden)
		return
	}

	// Resolve DNS and dial (proxy-side resolution prevents DNS rebinding)
	targetConn, resolvedIP, dialErr := p.policy.DialChecked(destHost, destPort)
	if dialErr != nil {
		reasonCode := "OTHER"
		var de *DialError
		if errors.As(dialErr, &de) && de.ReasonCode != "" {
			reasonCode = de.ReasonCode
			if de.ResolvedIP != "" {
				resolvedIP = de.ResolvedIP
			}
		}

		p.audit.Log(AuditEvent{
			DestHost:   destHost,
			DestPort:   destPort,
			ResolvedIP: resolvedIP,
			Decision:   "deny",
			ReasonCode: reasonCode,
			Method:     "CONNECT",
		})

		status := http.StatusBadGateway
		if reasonCode == "DNS_DENIED" {
			status = http.StatusForbidden
		}
		http.Error(w, "connection failed", status)
		return
	}

	p.audit.Log(AuditEvent{
		DestHost:   destHost,
		DestPort:   destPort,
		ResolvedIP: resolvedIP,
		Decision:   "allow",
		ReasonCode: "OK",
		Method:     "CONNECT",
	})

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		targetConn.Close()
		http.Error(w, "hijack not supported", http.StatusInternalServerError)
		return
	}

	clientConn, _, err := hijacker.Hijack()
	if err != nil {
		targetConn.Close()
		slog.Error("egress proxy: hijack failed", "error", err)
		return
	}

	_, _ = clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))

	// Bidirectional copy in background
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		defer clientConn.Close()
		defer targetConn.Close()

		// wait for BOTH copy directions to prevent goroutine leak
		done := make(chan struct{}, 2)
		go func() { io.Copy(targetConn, clientConn); done <- struct{}{} }()
		go func() { io.Copy(clientConn, targetConn); done <- struct{}{} }()
		<-done
		<-done
	}()
}

// hopByHopHeaders are headers that must not be forwarded by a proxy (RFC 2616 §13.5.1).
var hopByHopHeaders = []string{
	"Connection", "Keep-Alive", "Proxy-Authenticate",
	"Proxy-Authorization", "TE", "Trailers",
	"Transfer-Encoding", "Upgrade",
}

func (p *Proxy) handleHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Host == "" {
		p.audit.Log(AuditEvent{
			Decision:   "deny",
			ReasonCode: "INVALID_DESTINATION",
			Method:     "HTTP",
		})
		http.Error(w, "not a proxy request", http.StatusBadRequest)
		return
	}

	destHost := r.URL.Hostname()
	destPort := 80
	if portStr := r.URL.Port(); portStr != "" {
		// return error on invalid port instead of silently defaulting
		port, err := strconv.Atoi(portStr)
		if err != nil {
			p.audit.Log(AuditEvent{
				DestHost:   destHost,
				Decision:   "deny",
				ReasonCode: "INVALID_DESTINATION",
				Method:     "HTTP",
			})
			http.Error(w, "invalid port", http.StatusBadRequest)
			return
		}
		destPort = port
	}
	if destPort < 1 || destPort > 65535 {
		p.audit.Log(AuditEvent{
			DestHost:   destHost,
			DestPort:   destPort,
			Decision:   "deny",
			ReasonCode: "INVALID_DESTINATION",
			Method:     "HTTP",
		})
		http.Error(w, "port out of range", http.StatusBadRequest)
		return
	}

	result := p.policy.Check(destHost, destPort)
	if !result.Allowed {
		p.audit.Log(AuditEvent{
			DestHost:   destHost,
			DestPort:   destPort,
			Decision:   "deny",
			ReasonCode: result.ReasonCode,
			Method:     "HTTP",
		})
		http.Error(w, fmt.Sprintf("egress denied: %s", result.ReasonCode), http.StatusForbidden)
		return
	}

	// strip hop-by-hop headers before forwarding
	for _, h := range hopByHopHeaders {
		r.Header.Del(h)
	}

	// use DisableKeepAlives and close idle connections to prevent transport leak
	transport := &http.Transport{
		DialContext: func(_ context.Context, network, addr string) (net.Conn, error) {
			conn, _, dialErr := p.policy.DialChecked(destHost, destPort)
			return conn, dialErr
		},
		ResponseHeaderTimeout: 30 * time.Second,
		DisableKeepAlives:     true,
	}
	defer transport.CloseIdleConnections()

	r.RequestURI = ""
	resp, err := transport.RoundTrip(r)
	if err != nil {
		reasonCode := "OTHER"
		resolvedIP := ""
		var de *DialError
		if errors.As(err, &de) && de.ReasonCode != "" {
			reasonCode = de.ReasonCode
			resolvedIP = de.ResolvedIP
		}

		p.audit.Log(AuditEvent{
			DestHost:   destHost,
			DestPort:   destPort,
			ResolvedIP: resolvedIP,
			Decision:   "deny",
			ReasonCode: reasonCode,
			Method:     "HTTP",
		})

		status := http.StatusBadGateway
		if reasonCode == "DNS_DENIED" {
			status = http.StatusForbidden
		}
		http.Error(w, "upstream error", status)
		return
	}
	defer resp.Body.Close()

	p.audit.Log(AuditEvent{
		DestHost:   destHost,
		DestPort:   destPort,
		Decision:   "allow",
		ReasonCode: "OK",
		Method:     "HTTP",
	})

	// strip hop-by-hop headers from response
	respHeader := w.Header()
	for k, vv := range resp.Header {
		for _, v := range vv {
			respHeader.Add(k, v)
		}
	}
	for _, h := range hopByHopHeaders {
		respHeader.Del(h)
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// splitHostPort parses "host:port" with a default port of 443.
func splitHostPort(hostport string) (string, int, error) {
	host, portStr, err := net.SplitHostPort(hostport)
	if err != nil {
		// validate non-empty host when treating as bare hostname
		host = strings.TrimSpace(hostport)
		if host == "" {
			return "", 0, fmt.Errorf("empty host")
		}
		return host, 443, nil
	}
	if host == "" {
		return "", 0, fmt.Errorf("empty host")
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return "", 0, fmt.Errorf("invalid port: %w", err)
	}
	if port < 1 || port > 65535 {
		return "", 0, fmt.Errorf("port out of range: %d", port)
	}
	return host, port, nil
}

const (
	socks5Version        = 0x05
	socks5MethodNoAuth   = 0x00
	socks5MethodNoAccept = 0xFF

	socks5CmdConnect = 0x01

	socks5AtypIPv4   = 0x01
	socks5AtypDomain = 0x03
	socks5AtypIPv6   = 0x04
)

func (p *Proxy) handleSOCKS5(conn net.Conn, br *bufio.Reader) {
	defer conn.Close()

	ver, err := br.ReadByte()
	if err != nil || ver != socks5Version {
		return
	}

	nMethodsB, err := br.ReadByte()
	if err != nil {
		return
	}
	nMethods := int(nMethodsB)
	methods := make([]byte, nMethods)
	if _, err := io.ReadFull(br, methods); err != nil {
		return
	}

	selected := byte(socks5MethodNoAccept)
	for _, m := range methods {
		if m == socks5MethodNoAuth {
			selected = socks5MethodNoAuth
			break
		}
	}
	_, _ = conn.Write([]byte{socks5Version, selected})
	if selected != socks5MethodNoAuth {
		return
	}

	reqHeader := make([]byte, 4)
	if _, err := io.ReadFull(br, reqHeader); err != nil {
		return
	}
	if reqHeader[0] != socks5Version {
		return
	}

	cmd := reqHeader[1]
	atyp := reqHeader[3]

	if cmd != socks5CmdConnect {
		p.audit.Log(AuditEvent{
			Decision:   "deny",
			ReasonCode: "INVALID_DESTINATION",
			Method:     "SOCKS5",
		})
		_ = writeSOCKS5Reply(conn, 0x07) // Command not supported
		return
	}

	destHost, destPort, err := readSOCKS5DomainDest(br, atyp)
	if err != nil {
		p.audit.Log(AuditEvent{
			DestHost:   destHost,
			DestPort:   destPort,
			Decision:   "deny",
			ReasonCode: "INVALID_DESTINATION",
			Method:     "SOCKS5",
		})
		_ = writeSOCKS5Reply(conn, 0x08) // Address type not supported
		return
	}

	result := p.policy.Check(destHost, destPort)
	if !result.Allowed {
		p.audit.Log(AuditEvent{
			DestHost:   destHost,
			DestPort:   destPort,
			Decision:   "deny",
			ReasonCode: result.ReasonCode,
			Method:     "SOCKS5",
		})
		_ = writeSOCKS5Reply(conn, 0x02) // Connection not allowed by ruleset
		return
	}

	targetConn, resolvedIP, dialErr := p.policy.DialChecked(destHost, destPort)
	if dialErr != nil {
		reasonCode := "OTHER"
		var de *DialError
		if errors.As(dialErr, &de) && de.ReasonCode != "" {
			reasonCode = de.ReasonCode
			if de.ResolvedIP != "" {
				resolvedIP = de.ResolvedIP
			}
		}

		p.audit.Log(AuditEvent{
			DestHost:   destHost,
			DestPort:   destPort,
			ResolvedIP: resolvedIP,
			Decision:   "deny",
			ReasonCode: reasonCode,
			Method:     "SOCKS5",
		})
		_ = writeSOCKS5Reply(conn, 0x02) // Connection not allowed by ruleset
		return
	}
	p.audit.Log(AuditEvent{
		DestHost:   destHost,
		DestPort:   destPort,
		ResolvedIP: resolvedIP,
		Decision:   "allow",
		ReasonCode: "OK",
		Method:     "SOCKS5",
	})

	if err := writeSOCKS5Reply(conn, 0x00); err != nil {
		targetConn.Close()
		return
	}

	// Use the bufio.Reader-backed conn to avoid losing buffered bytes.
	clientConn := &preReadConn{Conn: conn, r: br}

	// Manage connection lifetime explicitly: when first copy finishes,
	// close both sides to unblock the other direction (prevents goroutine leak).
	done := make(chan struct{}, 2)
	go func() { io.Copy(targetConn, clientConn); done <- struct{}{} }()
	go func() { io.Copy(clientConn, targetConn); done <- struct{}{} }()
	<-done
	targetConn.Close()
	conn.Close()
	<-done
}

func readSOCKS5DomainDest(r *bufio.Reader, atyp byte) (host string, port int, _ error) {
	switch atyp {
	case socks5AtypDomain:
		lnB, err := r.ReadByte()
		if err != nil {
			return "", 0, err
		}
		ln := int(lnB)
		if ln <= 0 {
			return "", 0, errors.New("empty host")
		}
		hostBytes := make([]byte, ln)
		if _, err := io.ReadFull(r, hostBytes); err != nil {
			return "", 0, err
		}
		host = string(hostBytes)
		if strings.TrimSpace(host) != host {
			return "", 0, errors.New("host contains whitespace")
		}
		// Reject null bytes, control characters, and non-DNS characters
		// to prevent SSRF via DNS resolver edge cases.
		if strings.ContainsAny(host, "\x00\n\r\t /\\@#?") {
			return "", 0, errors.New("host contains invalid characters")
		}

	default:
		var skip int64
		switch atyp {
		case socks5AtypIPv4:
			skip = 4
		case socks5AtypIPv6:
			skip = 16
		default:
			skip = 0
		}
		if skip > 0 {
			_, _ = io.CopyN(io.Discard, r, skip)
		}
		_, _ = io.CopyN(io.Discard, r, 2) // port
		return "", 0, errors.New("unsupported address type")
	}

	portBuf := make([]byte, 2)
	if _, err := io.ReadFull(r, portBuf); err != nil {
		return host, 0, err
	}
	port = int(binary.BigEndian.Uint16(portBuf))
	if port < 1 || port > 65535 {
		return host, port, errors.New("port out of range")
	}
	return host, port, nil
}

func writeSOCKS5Reply(w io.Writer, rep byte) error {
	// Minimal reply: bind addr 0.0.0.0:0
	_, err := w.Write([]byte{
		socks5Version,
		rep,
		0x00,                   // RSV
		0x01,                   // ATYP IPv4
		0x00, 0x00, 0x00, 0x00, // BND.ADDR
		0x00, 0x00, // BND.PORT
	})
	return err
}
