package version

import (
	"fmt"
	"strings"
	"testing"
)

func TestFull_DefaultValues(t *testing.T) {
	t.Parallel()

	got := Full()
	if !strings.HasPrefix(got, "0.1.0-dev") {
		t.Errorf("expected prefix 0.1.0-dev, got %s", got)
	}
	if !strings.Contains(got, "commit=") {
		t.Errorf("expected commit= in output, got %s", got)
	}
	if !strings.Contains(got, "date=") {
		t.Errorf("expected date= in output, got %s", got)
	}
}

func TestFull_Format(t *testing.T) {
	// Not parallel: mutates package-level vars (Version, Commit, BuildDate).

	// Save originals and restore after test
	origVersion, origCommit, origDate := Version, Commit, BuildDate
	t.Cleanup(func() {
		Version = origVersion
		Commit = origCommit
		BuildDate = origDate
	})

	Version = "1.2.3"
	Commit = "abc123"
	BuildDate = "2025-06-15T10:00:00Z"

	expected := "1.2.3 (commit=abc123 date=2025-06-15T10:00:00Z)"
	got := Full()
	if got != expected {
		t.Errorf("expected %q, got %q", expected, got)
	}
}

func TestCompare(t *testing.T) {
	t.Parallel()

	tests := []struct {
		a, b string
		want int
	}{
		{"0.1.0", "0.1.0", 0},
		{"0.2.0", "0.1.0", 1},
		{"0.1.0", "0.2.0", -1},
		{"1.0.0", "0.99.99", 1},
		{"0.10.0", "0.2.0", 1},     // numeric, not lexicographic
		{"0.1.0-dev", "0.1.0", 0},  // pre-release suffix ignored
		{"1.2.3-rc1", "1.2.3", 0},  // pre-release suffix ignored
		{"0.1.0", "0.1.0-dev", 0},  // symmetric
		{"2.0.0", "1.99.99", 1},
		{"0.0.1", "0.0.0", 1},
		{"", "0.1.0", -1},          // empty treated as 0.0.0
	}

	for _, tt := range tests {
		t.Run(fmt.Sprintf("%s_vs_%s", tt.a, tt.b), func(t *testing.T) {
			t.Parallel()
			got := Compare(tt.a, tt.b)
			if got != tt.want {
				t.Errorf("Compare(%q, %q) = %d, want %d", tt.a, tt.b, got, tt.want)
			}
		})
	}
}
