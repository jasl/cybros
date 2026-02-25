package egressproxy

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"time"

	"cybros.ai/nexus/netpolicy"
	"cybros.ai/nexus/protocol"
)

// Policy evaluates whether a given destination is allowed under
// a directive's network capability.
type Policy struct {
	mode    string // none/allowlist/unrestricted
	entries []netpolicy.AllowlistEntry

	lookupIP    func(host string) ([]net.IP, error)
	dialTimeout func(network, address string, timeout time.Duration) (net.Conn, error)
}

// NewPolicy creates an enforcement policy from a NetCapabilityV1.
// Returns a deny-all policy if cap is nil.
func NewPolicy(cap *protocol.NetCapabilityV1) (*Policy, error) {
	if cap == nil {
		return &Policy{
			mode:        "none",
			lookupIP:    net.LookupIP,
			dialTimeout: net.DialTimeout,
		}, nil
	}

	p := &Policy{
		mode:        cap.Mode,
		lookupIP:    net.LookupIP,
		dialTimeout: net.DialTimeout,
	}
	if cap.Mode == "allowlist" {
		for _, raw := range cap.Allow {
			entry, err := netpolicy.ParseAllowlistEntry(raw)
			if err != nil {
				return nil, fmt.Errorf("invalid allowlist entry %q: %w", raw, err)
			}
			p.entries = append(p.entries, entry)
		}
	}
	return p, nil
}

// CheckResult contains the decision and reason for an egress check.
type CheckResult struct {
	Allowed    bool
	ReasonCode string
}

// Check evaluates whether connecting to destHost:destPort is allowed.
func (p *Policy) Check(destHost string, destPort int) CheckResult {
	switch p.mode {
	case "none":
		return CheckResult{Allowed: false, ReasonCode: "NET_MODE_NONE"}

	case "unrestricted":
		return CheckResult{Allowed: true, ReasonCode: "OK"}

	case "allowlist":
		for _, entry := range p.entries {
			if netpolicy.Match(entry, destHost, destPort) {
				return CheckResult{Allowed: true, ReasonCode: "OK"}
			}
		}
		return CheckResult{Allowed: false, ReasonCode: "NOT_IN_ALLOWLIST"}

	default:
		return CheckResult{Allowed: false, ReasonCode: "INTERNAL_ERROR"}
	}
}

// DialError indicates that a dial was rejected or failed with a specific reason code.
// It is used to map errors to stable audit reason codes (V1).
type DialError struct {
	ReasonCode string
	ResolvedIP string
	Err        error
}

func (e *DialError) Error() string { return e.Err.Error() }
func (e *DialError) Unwrap() error { return e.Err }

// ResolveAndCheck performs DNS resolution and validates that all resolved IPs
// are routable (non-private). Returns the first usable IP.
func (p *Policy) ResolveAndCheck(destHost string) (net.IP, error) {
	ips, err := p.lookupIP(destHost)
	if err != nil {
		return nil, &DialError{
			ReasonCode: "DNS_DENIED",
			Err:        fmt.Errorf("DNS lookup for %s failed: %w", destHost, err),
		}
	}

	for _, ip := range ips {
		if !netpolicy.IsPrivateIP(ip) {
			return ip, nil
		}
	}

	var firstIP string
	if len(ips) > 0 {
		firstIP = ips[0].String()
	}
	return nil, &DialError{
		ReasonCode: "DNS_DENIED",
		ResolvedIP: firstIP,
		Err:        fmt.Errorf("all resolved IPs for %s are private/non-routable", destHost),
	}
}

// DialChecked resolves the hostname, validates the resolved IP, and dials.
// Returns the connection and the resolved IP string (for audit logging).
func (p *Policy) DialChecked(destHost string, destPort int) (net.Conn, string, error) {
	ip, err := p.ResolveAndCheck(destHost)
	if err != nil {
		var de *DialError
		if errors.As(err, &de) {
			return nil, de.ResolvedIP, de
		}
		return nil, "", err
	}

	// FIX C1: use net.JoinHostPort for correct IPv6 address formatting
	// (e.g., "[2001:db8::1]:443" instead of "2001:db8::1:443").
	addr := net.JoinHostPort(ip.String(), strconv.Itoa(destPort))
	conn, err := p.dialTimeout("tcp", addr, dialTimeout)
	if err != nil {
		return nil, ip.String(), &DialError{
			ReasonCode: "OTHER",
			ResolvedIP: ip.String(),
			Err:        fmt.Errorf("dial %s: %w", addr, err),
		}
	}
	return conn, ip.String(), nil
}

const dialTimeout = 30 * time.Second
