package sandbox

import (
	"runtime"
	"testing"

	"cybros.ai/nexus/protocol"
)

func TestApplyCgroupLimits_ZeroLimits(t *testing.T) {
	t.Parallel()

	// Zero limits should return nil, nil (no-op) on all platforms.
	cg, err := ApplyCgroupLimits("d-1", 1234, protocol.Limits{})
	if err != nil {
		t.Fatalf("expected no error for zero limits, got: %v", err)
	}
	if cg != nil {
		t.Fatal("expected nil limiter for zero limits")
	}
}

func TestApplyCgroupLimits_NegativeLimits(t *testing.T) {
	t.Parallel()

	// Negative CPU/MemoryMB should also be treated as zero (no-op).
	cg, err := ApplyCgroupLimits("d-neg", 1234, protocol.Limits{CPU: -1, MemoryMB: -1})
	if err != nil {
		t.Fatalf("expected no error for negative limits, got: %v", err)
	}
	if cg != nil {
		t.Fatal("expected nil limiter for negative limits")
	}
}

func TestCgroupLimiter_CleanupNilSafe(t *testing.T) {
	t.Parallel()

	// Cleanup on nil should not panic.
	var cg *CgroupLimiter
	cg.Cleanup() // should be a no-op
}

func TestApplyCgroupLimits_InvalidDirectiveID(t *testing.T) {
	t.Parallel()

	if runtime.GOOS != "linux" {
		t.Skip("cgroup validation only applies on Linux")
	}

	tests := []struct {
		name string
		id   string
	}{
		{"path_traversal", "../escape"},
		{"slash", "dir/subdir"},
		{"empty", ""},
		{"dot", "."},
		{"dotdot", ".."},
		{"space", "has space"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			_, err := ApplyCgroupLimits(tt.id, 1234, protocol.Limits{CPU: 1000, MemoryMB: 256})
			if err == nil {
				t.Errorf("expected error for invalid directive ID %q", tt.id)
			}
		})
	}
}

func TestApplyCgroupLimits_BoundsCheck(t *testing.T) {
	t.Parallel()

	if runtime.GOOS != "linux" {
		t.Skip("cgroup bounds check only applies on Linux")
	}

	// Use values that exceed the limits defined in cgroup_linux.go
	// (maxCPUMillicores = 1024000, maxMemoryMB = 1 << 20 = 1048576).
	tests := []struct {
		name   string
		limits protocol.Limits
	}{
		{"cpu_exceeds_max", protocol.Limits{CPU: 1024001}},
		{"memory_exceeds_max", protocol.Limits{MemoryMB: 1048577}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			_, err := ApplyCgroupLimits("d-bounds", 1234, tt.limits)
			if err == nil {
				t.Error("expected error for exceeding bounds")
			}
		})
	}
}
