package netpolicy

import "testing"

func TestParseAndMatch(t *testing.T) {
	entry, err := ParseAllowlistEntry("github.com:443")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if !Match(entry, "github.com", 443) {
		t.Fatalf("expected match")
	}
	if Match(entry, "api.github.com", 443) {
		t.Fatalf("did not expect match for subdomain")
	}

	w, err := ParseAllowlistEntry("*.example.com:443")
	if err != nil {
		t.Fatalf("parse wildcard: %v", err)
	}
	if Match(w, "example.com", 443) {
		t.Fatalf("wildcard should not match root domain")
	}
	if !Match(w, "a.example.com", 443) {
		t.Fatalf("wildcard should match subdomain")
	}
	if !Match(w, "b.a.example.com", 443) {
		t.Fatalf("wildcard should match nested subdomain")
	}
}

func TestRejectIPLiteral(t *testing.T) {
	if _, err := ParseAllowlistEntry("1.2.3.4:443"); err == nil {
		t.Fatalf("expected IP literal rejected")
	}
	if _, err := ParseAllowlistEntry("[::1]:443"); err == nil {
		t.Fatalf("expected IPv6 literal rejected")
	}
}
