package daemon

import (
	"context"
	"testing"
	"time"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/protocol"
)

// TestRedactRepoURL and TestIsAllowedRepoScheme moved to sandbox/prepare_test.go

func TestIsValidFacilityID(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		id   string
		want bool
	}{
		{name: "uuid", id: "0191a3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d", want: true},
		{name: "alphanum", id: "facility123", want: true},
		{name: "with-underscores", id: "my_facility", want: true},
		{name: "with-dashes", id: "my-facility", want: true},
		{name: "empty", id: "", want: false},
		{name: "dot", id: ".", want: false},
		{name: "dotdot", id: "..", want: false},
		{name: "slash-traversal", id: "../etc/passwd", want: false},
		{name: "with-slash", id: "abc/def", want: false},
		{name: "with-space", id: "abc def", want: false},
		{name: "with-colon", id: "abc:def", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := isValidFacilityID(tt.id)
			if got != tt.want {
				t.Fatalf("isValidFacilityID(%q) = %v, want %v", tt.id, got, tt.want)
			}
		})
	}
}

func TestSleepCtx_ContextCanceled(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	start := time.Now()
	ok := sleepCtx(ctx, 10*time.Second)
	elapsed := time.Since(start)

	if ok {
		t.Fatal("expected sleepCtx to return false on canceled context")
	}
	if elapsed > 1*time.Second {
		t.Fatalf("sleepCtx did not return quickly on canceled context: %v", elapsed)
	}
}

func TestSleepCtx_NormalSleep(t *testing.T) {
	t.Parallel()

	ctx := context.Background()

	start := time.Now()
	ok := sleepCtx(ctx, 50*time.Millisecond)
	elapsed := time.Since(start)

	if !ok {
		t.Fatal("expected sleepCtx to return true on normal sleep")
	}
	if elapsed < 40*time.Millisecond {
		t.Fatalf("sleepCtx returned too quickly: %v", elapsed)
	}
}

func TestCappedDuration(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		seconds int
		want    time.Duration
	}{
		{name: "normal", seconds: 10, want: 10 * time.Second},
		{name: "zero", seconds: 0, want: 0},
		{name: "over-cap", seconds: 600, want: maxRetryAfter},
		{name: "exact-cap", seconds: 300, want: 5 * time.Minute},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got := cappedDuration(tt.seconds)
			if got != tt.want {
				t.Fatalf("cappedDuration(%d) = %v, want %v", tt.seconds, got, tt.want)
			}
		})
	}
}

func TestTokenHolder(t *testing.T) {
	t.Parallel()

	h := newTokenHolder("initial")
	if got := h.Get(); got != "initial" {
		t.Fatalf("expected initial token, got %q", got)
	}

	h.Set("refreshed")
	if got := h.Get(); got != "refreshed" {
		t.Fatalf("expected refreshed token, got %q", got)
	}

	// Empty string should not overwrite
	h.Set("")
	if got := h.Get(); got != "refreshed" {
		t.Fatalf("empty Set should not overwrite, got %q", got)
	}
}

func TestBuildDirectiveEnv(t *testing.T) {
	t.Parallel()

	cfg := config.Config{TerritoryID: "t1"}
	spec := protocol.DirectiveSpec{
		Facility:       protocol.FacilitySpec{ID: "f1", Mount: "/workspace"},
		SandboxProfile: "host",
	}

	env := buildDirectiveEnv(cfg, "d1", spec)

	// Check required env vars are present
	checks := map[string]string{
		"NO_COLOR":               "1",
		"TERM":                   "dumb",
		"PAGER":                  "cat",
		"GIT_PAGER":              "cat",
		"CYBROS_NEXUS":           "1",
		"CYBROS_DIRECTIVE_ID":    "d1",
		"CYBROS_FACILITY_ID":     "f1",
		"CYBROS_TERRITORY_ID":    "t1",
		"CYBROS_SANDBOX_PROFILE": "host",
		"CYBROS_WORKSPACE":       "/workspace",
		"CI":                     "true",
	}
	for k, want := range checks {
		got, ok := env[k]
		if !ok {
			t.Errorf("missing env var %s", k)
			continue
		}
		if got != want {
			t.Errorf("env[%s] = %q, want %q", k, got, want)
		}
	}
}
