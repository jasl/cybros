package netpolicy

import (
	"errors"
	"fmt"
	"net"
	"regexp"
	"strconv"
	"strings"
)

var (
	errInvalidFormat = errors.New("invalid allowlist entry format, expected host:port")
	// Mirror the schema intent: localhost OR (optional '*.' + domain with at least one dot)
	hostRe = regexp.MustCompile(`(?i)^(localhost|(\*\.)?([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+)$`)
)

type AllowlistEntry struct {
	Raw      string
	Host     string // normalized lower-case, no trailing dot, no '*.' prefix
	Port     int
	Wildcard bool
}

func NormalizeHost(host string) string {
	h := strings.TrimSpace(host)
	h = strings.TrimSuffix(h, ".")
	h = strings.ToLower(h)
	return h
}

func isIPLiteral(host string) bool {
	h := strings.TrimSpace(host)
	if strings.HasPrefix(h, "[") && strings.HasSuffix(h, "]") {
		return true
	}
	if strings.Contains(h, ":") {
		return true // naive IPv6 detection; V1 forbids
	}
	// net.ParseIP catches IPv4 dotted and bare IPv6.
	if ip := net.ParseIP(h); ip != nil {
		return true
	}
	return false
}

func ParseAllowlistEntry(s string) (AllowlistEntry, error) {
	raw := strings.TrimSpace(s)
	idx := strings.LastIndex(raw, ":")
	if idx <= 0 || idx == len(raw)-1 {
		return AllowlistEntry{}, errInvalidFormat
	}
	hostPart := raw[:idx]
	portPart := raw[idx+1:]

	port, err := strconv.Atoi(portPart)
	if err != nil {
		return AllowlistEntry{}, fmt.Errorf("invalid port %q: %w", portPart, err)
	}
	if port < 1 || port > 65535 {
		return AllowlistEntry{}, fmt.Errorf("port out of range: %d", port)
	}

	if isIPLiteral(hostPart) {
		return AllowlistEntry{}, fmt.Errorf("IP literal is not allowed in V1: %q", hostPart)
	}

	wildcard := false
	host := hostPart
	if strings.HasPrefix(host, "*.") {
		wildcard = true
		host = host[2:]
	}
	host = NormalizeHost(host)

	// Validate host against schema intent
	candidate := host
	if wildcard {
		candidate = "*." + host
	}
	if !hostRe.MatchString(candidate) {
		return AllowlistEntry{}, fmt.Errorf("invalid host: %q", hostPart)
	}

	return AllowlistEntry{
		Raw:      raw,
		Host:     host,
		Port:     port,
		Wildcard: wildcard,
	}, nil
}

func Match(entry AllowlistEntry, destHost string, destPort int) bool {
	h := NormalizeHost(destHost)
	if destPort != entry.Port {
		return false
	}
	if entry.Wildcard {
		if h == entry.Host {
			return false // '*.example.com' does not match 'example.com'
		}
		return strings.HasSuffix(h, "."+entry.Host)
	}
	return h == entry.Host
}
