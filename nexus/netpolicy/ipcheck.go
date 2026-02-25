package netpolicy

import "net"

// privateCIDRs contains RFC1918, loopback, link-local, and other non-routable ranges.
var privateCIDRs []*net.IPNet

func init() {
	for _, cidr := range []string{
		"0.0.0.0/8",      // "this" network (RFC1122)
		"10.0.0.0/8",     // RFC1918
		"172.16.0.0/12",  // RFC1918
		"192.168.0.0/16", // RFC1918
		"127.0.0.0/8",    // loopback
		"169.254.0.0/16", // link-local IPv4
		"100.64.0.0/10",  // shared address space (CGNAT)
		"224.0.0.0/4",    // multicast
		"240.0.0.0/4",    // reserved for future use
		"::1/128",        // loopback IPv6
		"fc00::/7",       // unique-local IPv6
		"fe80::/10",      // link-local IPv6
	} {
		_, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			panic("bad hardcoded CIDR " + cidr + ": " + err.Error())
		}
		privateCIDRs = append(privateCIDRs, ipNet)
	}
}

// IsPrivateIP returns true if the given IP is in a private, loopback,
// link-local, or otherwise non-routable range.
// Used by the egress proxy to deny connections to internal addresses.
func IsPrivateIP(ip net.IP) bool {
	if ip == nil {
		return true // FIX C5: fail-closed — treat nil as non-routable
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
		return true
	}
	for _, cidr := range privateCIDRs {
		if cidr.Contains(ip) {
			return true
		}
	}
	return false
}
