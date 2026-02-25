package egressproxy

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"testing"
	"time"

	"cybros.ai/nexus/protocol"
)

func startSOCKS5TestProxy(t *testing.T, policy *Policy, auditBuf *bytes.Buffer) (socketPath string) {
	t.Helper()

	socketPath = tempSocketPath(t)

	audit := NewAuditLogger(auditBuf, "test-directive")
	proxy, err := New(socketPath, policy, audit)
	if err != nil {
		t.Fatalf("New proxy: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go proxy.Serve(ctx)

	// Wait for proxy to be ready
	for i := 0; i < 50; i++ {
		conn, err := net.DialTimeout("unix", socketPath, 100*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	return socketPath
}

func socks5Handshake(t *testing.T, conn net.Conn) {
	t.Helper()

	_, err := conn.Write([]byte{0x05, 0x01, 0x00})
	if err != nil {
		t.Fatalf("write handshake: %v", err)
	}

	resp := make([]byte, 2)
	if _, err := io.ReadFull(conn, resp); err != nil {
		t.Fatalf("read handshake: %v", err)
	}
	if resp[0] != 0x05 || resp[1] != 0x00 {
		t.Fatalf("handshake resp = %#v, want [0x05 0x00]", resp)
	}
}

func socks5ConnectDomain(t *testing.T, conn net.Conn, host string, port int) byte {
	t.Helper()

	hostB := []byte(host)
	req := make([]byte, 0, 4+1+len(hostB)+2)
	req = append(req, 0x05, 0x01, 0x00, 0x03) // VER, CMD=CONNECT, RSV, ATYP=DOMAIN
	req = append(req, byte(len(hostB)))
	req = append(req, hostB...)
	portB := make([]byte, 2)
	binary.BigEndian.PutUint16(portB, uint16(port))
	req = append(req, portB...)

	if _, err := conn.Write(req); err != nil {
		t.Fatalf("write connect: %v", err)
	}

	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		t.Fatalf("read reply hdr: %v", err)
	}
	if hdr[0] != 0x05 {
		t.Fatalf("reply ver=%#x, want 0x05", hdr[0])
	}

	// Read the remaining address/port fields based on ATYP.
	switch hdr[3] {
	case 0x01: // IPv4
		_, _ = io.CopyN(io.Discard, conn, 4+2)
	case 0x03: // Domain
		ln := make([]byte, 1)
		if _, err := io.ReadFull(conn, ln); err != nil {
			t.Fatalf("read domain len: %v", err)
		}
		_, _ = io.CopyN(io.Discard, conn, int64(ln[0])+2)
	case 0x04: // IPv6
		_, _ = io.CopyN(io.Discard, conn, 16+2)
	default:
		_, _ = io.CopyN(io.Discard, conn, 2)
	}

	return hdr[1] // REP
}

func TestSOCKS5_Connect_Allowed_AllowlistHit(t *testing.T) {
	cap := &protocol.NetCapabilityV1{
		Mode:  "allowlist",
		Allow: []string{"example.com:443"},
	}
	policy, err := NewPolicy(cap)
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}

	// Stub out DNS + dialing to avoid real network usage.
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { _ = serverConn.Close() })

	policy.lookupIP = func(host string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("93.184.216.34")}, nil
	}
	policy.dialTimeout = func(network, address string, timeout time.Duration) (net.Conn, error) {
		return clientConn, nil
	}

	var auditBuf bytes.Buffer
	socketPath := startSOCKS5TestProxy(t, policy, &auditBuf)

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	socks5Handshake(t, conn)
	rep := socks5ConnectDomain(t, conn, "example.com", 443)
	if rep != 0x00 {
		t.Fatalf("rep=%#x, want 0x00", rep)
	}

	// Verify the tunnel is established by round-tripping bytes through the pipe.
	_, err = conn.Write([]byte("ping"))
	if err != nil {
		t.Fatalf("write ping: %v", err)
	}

	buf := make([]byte, 4)
	if _, err := io.ReadFull(serverConn, buf); err != nil {
		t.Fatalf("read server: %v", err)
	}
	if string(buf) != "ping" {
		t.Fatalf("server got %q, want %q", string(buf), "ping")
	}

	_, err = serverConn.Write([]byte("pong"))
	if err != nil {
		t.Fatalf("write pong: %v", err)
	}
	buf2 := make([]byte, 4)
	if _, err := io.ReadFull(conn, buf2); err != nil {
		t.Fatalf("read client: %v", err)
	}
	if string(buf2) != "pong" {
		t.Fatalf("client got %q, want %q", string(buf2), "pong")
	}

	// Audit should include allow + OK.
	lines := bytes.Split(bytes.TrimSpace(auditBuf.Bytes()), []byte("\n"))
	if len(lines) == 0 {
		t.Fatal("expected at least one audit line")
	}
	var event map[string]any
	if err := json.Unmarshal(lines[len(lines)-1], &event); err != nil {
		t.Fatalf("unmarshal audit: %v", err)
	}
	if event["decision"] != "allow" || event["reason_code"] != "OK" {
		t.Fatalf("audit=%v, want decision=allow reason_code=OK", event)
	}
}

func TestSOCKS5_Connect_Denied_ModeNone(t *testing.T) {
	policy, err := NewPolicy(nil) // nil = deny-all
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}

	var auditBuf bytes.Buffer
	socketPath := startSOCKS5TestProxy(t, policy, &auditBuf)

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	socks5Handshake(t, conn)
	rep := socks5ConnectDomain(t, conn, "example.com", 443)
	if rep == 0x00 {
		t.Fatalf("rep=%#x, want non-zero deny", rep)
	}
	if !bytes.Contains(auditBuf.Bytes(), []byte(`"reason_code":"NET_MODE_NONE"`)) {
		t.Fatalf("expected NET_MODE_NONE in audit: %s", auditBuf.String())
	}
}

func TestSOCKS5_Connect_Denied_NotInAllowlist(t *testing.T) {
	cap := &protocol.NetCapabilityV1{
		Mode:  "allowlist",
		Allow: []string{"github.com:443"},
	}
	policy, err := NewPolicy(cap)
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}

	var auditBuf bytes.Buffer
	socketPath := startSOCKS5TestProxy(t, policy, &auditBuf)

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	socks5Handshake(t, conn)
	rep := socks5ConnectDomain(t, conn, "evil.com", 443)
	if rep == 0x00 {
		t.Fatalf("rep=%#x, want non-zero deny", rep)
	}
	if !bytes.Contains(auditBuf.Bytes(), []byte(`"reason_code":"NOT_IN_ALLOWLIST"`)) {
		t.Fatalf("expected NOT_IN_ALLOWLIST in audit: %s", auditBuf.String())
	}
}

func TestSOCKS5_ATYP_IPv4_Denied(t *testing.T) {
	policy, err := NewPolicy(&protocol.NetCapabilityV1{Mode: "unrestricted"})
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}

	var auditBuf bytes.Buffer
	socketPath := startSOCKS5TestProxy(t, policy, &auditBuf)

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	socks5Handshake(t, conn)

	// Connect request with ATYP=IPv4 should be rejected.
	req := []byte{
		0x05, 0x01, 0x00, 0x01, // VER, CMD=CONNECT, RSV, ATYP=IPv4
		1, 2, 3, 4, // IP
		0x01, 0xbb, // port 443
	}
	if _, err := conn.Write(req); err != nil {
		t.Fatalf("write connect: %v", err)
	}
	reply := make([]byte, 10)
	if _, err := io.ReadFull(conn, reply); err != nil {
		t.Fatalf("read reply: %v", err)
	}
	if reply[1] == 0x00 {
		t.Fatalf("rep=%#x, want non-zero deny", reply[1])
	}
	if !bytes.Contains(auditBuf.Bytes(), []byte(`"reason_code":"INVALID_DESTINATION"`)) {
		t.Fatalf("expected INVALID_DESTINATION in audit: %s", auditBuf.String())
	}
}

func TestSOCKS5_Command_NotConnect_Denied(t *testing.T) {
	policy, err := NewPolicy(&protocol.NetCapabilityV1{Mode: "unrestricted"})
	if err != nil {
		t.Fatalf("NewPolicy: %v", err)
	}

	var auditBuf bytes.Buffer
	socketPath := startSOCKS5TestProxy(t, policy, &auditBuf)

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	socks5Handshake(t, conn)

	// Request with CMD=BIND should be rejected.
	req := []byte{
		0x05, 0x02, 0x00, 0x03, // VER, CMD=BIND, RSV, ATYP=DOMAIN
		0x03, 'f', 'o', 'o',
		0x01, 0xbb, // port 443
	}
	if _, err := conn.Write(req); err != nil {
		t.Fatalf("write request: %v", err)
	}
	reply := make([]byte, 10)
	if _, err := io.ReadFull(conn, reply); err != nil {
		t.Fatalf("read reply: %v", err)
	}
	if reply[1] == 0x00 {
		t.Fatalf("rep=%#x, want non-zero deny", reply[1])
	}
	if !bytes.Contains(auditBuf.Bytes(), []byte(`"reason_code":"INVALID_DESTINATION"`)) {
		t.Fatalf("expected INVALID_DESTINATION in audit: %s", auditBuf.String())
	}
}
