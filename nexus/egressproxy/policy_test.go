package egressproxy

import (
	"testing"

	"cybros.ai/nexus/protocol"
)

func TestNewPolicy_NilCapability(t *testing.T) {
	p, err := NewPolicy(nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	result := p.Check("example.com", 443)
	if result.Allowed {
		t.Error("nil capability should deny all")
	}
	if result.ReasonCode != "NET_MODE_NONE" {
		t.Errorf("reason = %q, want NET_MODE_NONE", result.ReasonCode)
	}
}

func TestPolicy_ModeNone(t *testing.T) {
	p, _ := NewPolicy(&protocol.NetCapabilityV1{Mode: "none"})
	result := p.Check("example.com", 443)
	if result.Allowed {
		t.Error("mode=none should deny")
	}
	if result.ReasonCode != "NET_MODE_NONE" {
		t.Errorf("reason = %q", result.ReasonCode)
	}
}

func TestPolicy_ModeUnrestricted(t *testing.T) {
	p, _ := NewPolicy(&protocol.NetCapabilityV1{Mode: "unrestricted"})
	result := p.Check("example.com", 443)
	if !result.Allowed {
		t.Error("mode=unrestricted should allow")
	}
}

func TestPolicy_Allowlist(t *testing.T) {
	cap := &protocol.NetCapabilityV1{
		Mode: "allowlist",
		Allow: []string{
			"github.com:443",
			"*.npmjs.org:443",
		},
	}
	p, err := NewPolicy(cap)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	tests := []struct {
		host    string
		port    int
		allowed bool
		reason  string
	}{
		{"github.com", 443, true, "OK"},
		{"github.com", 80, false, "NOT_IN_ALLOWLIST"},
		{"registry.npmjs.org", 443, true, "OK"},
		{"npmjs.org", 443, false, "NOT_IN_ALLOWLIST"}, // wildcard doesn't match base
		{"evil.com", 443, false, "NOT_IN_ALLOWLIST"},
	}

	for _, tt := range tests {
		result := p.Check(tt.host, tt.port)
		if result.Allowed != tt.allowed {
			t.Errorf("Check(%q, %d).Allowed = %v, want %v", tt.host, tt.port, result.Allowed, tt.allowed)
		}
		if result.ReasonCode != tt.reason {
			t.Errorf("Check(%q, %d).ReasonCode = %q, want %q", tt.host, tt.port, result.ReasonCode, tt.reason)
		}
	}
}

func TestNewPolicy_InvalidEntry(t *testing.T) {
	cap := &protocol.NetCapabilityV1{
		Mode:  "allowlist",
		Allow: []string{"invalid-entry"},
	}
	_, err := NewPolicy(cap)
	if err == nil {
		t.Fatal("expected error for invalid entry")
	}
}
