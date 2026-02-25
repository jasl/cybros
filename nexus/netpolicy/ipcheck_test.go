package netpolicy

import (
	"net"
	"testing"
)

func TestIsPrivateIP(t *testing.T) {
	tests := []struct {
		ip      string
		private bool
	}{
		// Private ranges (RFC1918)
		{"10.0.0.1", true},
		{"10.255.255.255", true},
		{"172.16.0.1", true},
		{"172.31.255.255", true},
		{"192.168.0.1", true},
		{"192.168.255.255", true},

		// Loopback
		{"127.0.0.1", true},
		{"127.255.255.255", true},

		// Link-local
		{"169.254.1.1", true},

		// CGNAT
		{"100.64.0.1", true},
		{"100.127.255.255", true},

		// IPv6 private
		{"::1", true},
		{"fc00::1", true},
		{"fd00::1", true},
		{"fe80::1", true},

		// Public IPs — should NOT be private
		{"8.8.8.8", false},
		{"1.1.1.1", false},
		{"104.16.0.1", false},
		{"172.32.0.1", false},   // just outside 172.16.0.0/12
		{"100.128.0.1", false},  // just outside CGNAT
		{"2606:4700::1", false}, // public IPv6

		// "This" network (0.0.0.0/8)
		{"0.0.0.0", true},
		{"0.255.255.255", true},

		// Multicast (224.0.0.0/4)
		{"224.0.0.1", true},
		{"239.255.255.255", true},

		// Reserved (240.0.0.0/4)
		{"240.0.0.1", true},
		{"255.255.255.254", true},

		// Edge: not in RFC1918
		{"192.169.0.1", false},
		{"11.0.0.1", false},
	}

	for _, tt := range tests {
		ip := net.ParseIP(tt.ip)
		if ip == nil {
			t.Fatalf("failed to parse IP: %s", tt.ip)
		}
		got := IsPrivateIP(ip)
		if got != tt.private {
			t.Errorf("IsPrivateIP(%s) = %v, want %v", tt.ip, got, tt.private)
		}
	}
}

func TestIsPrivateIP_Nil(t *testing.T) {
	// FIX C5: nil should be treated as non-routable (fail-closed)
	if !IsPrivateIP(nil) {
		t.Error("IsPrivateIP(nil) = false, want true (fail-closed)")
	}
}
