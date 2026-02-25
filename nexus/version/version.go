package version

import (
	"strconv"
	"strings"
)

// Build-time metadata injected via -ldflags.
// Example: go build -ldflags "-X cybros.ai/nexus/version.Version=0.1.0 -X cybros.ai/nexus/version.Commit=abc123 -X cybros.ai/nexus/version.BuildDate=2025-01-01T00:00:00Z"
var (
	Version   = "0.1.0-dev"
	Commit    = "unknown"
	BuildDate = "unknown"
)

// Full returns a human-readable version string including commit and build date.
func Full() string {
	return Version + " (commit=" + Commit + " date=" + BuildDate + ")"
}

// Compare compares two semantic version strings (e.g., "1.2.3", "0.10.0-dev").
// Returns -1 if a < b, 0 if a == b, +1 if a > b.
// Only the numeric X.Y.Z prefix is compared; pre-release suffixes are ignored.
func Compare(a, b string) int {
	aNums := parseSemver(a)
	bNums := parseSemver(b)
	for i := 0; i < 3; i++ {
		if aNums[i] < bNums[i] {
			return -1
		}
		if aNums[i] > bNums[i] {
			return 1
		}
	}
	return 0
}

func parseSemver(v string) [3]int {
	// Strip pre-release suffix (e.g., "-dev", "-rc1").
	if idx := strings.IndexByte(v, '-'); idx >= 0 {
		v = v[:idx]
	}
	parts := strings.SplitN(v, ".", 3)
	var nums [3]int
	for i := 0; i < 3 && i < len(parts); i++ {
		n, _ := strconv.Atoi(parts[i])
		nums[i] = n
	}
	return nums
}
