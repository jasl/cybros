package landlock

import (
	"runtime"
	"testing"
)

func TestNewRuleset(t *testing.T) {
	rs := NewRuleset()
	if rs == nil {
		t.Fatal("NewRuleset returned nil")
	}
}

func TestAddWritable(t *testing.T) {
	rs := NewRuleset()
	rs.AddWritable("/tmp", "/workspace")
	if len(rs.writablePaths) < 2 {
		t.Fatalf("expected at least 2 writable paths, got %d", len(rs.writablePaths))
	}
}

func TestAddReadOnly(t *testing.T) {
	rs := NewRuleset()
	rs.AddReadOnly("/usr", "/etc")
	if len(rs.readOnlyPaths) < 2 {
		t.Fatalf("expected at least 2 read-only paths, got %d", len(rs.readOnlyPaths))
	}
}

func TestAvailable(t *testing.T) {
	result := Available()
	if runtime.GOOS != "linux" && result {
		t.Error("Available() should return false on non-Linux")
	}
	// On Linux, result depends on kernel version — we accept either
	t.Logf("Available() = %v (GOOS=%s)", result, runtime.GOOS)
}

func TestApplyEmpty(t *testing.T) {
	rs := NewRuleset()
	// Empty ruleset should be a no-op on all platforms
	if err := rs.Apply(); err != nil {
		t.Fatalf("Apply() with empty ruleset should succeed: %v", err)
	}
}

func TestApplyNonLinux(t *testing.T) {
	if runtime.GOOS == "linux" {
		t.Skip("skipping non-Linux test on Linux")
	}
	rs := NewRuleset()
	rs.AddWritable("/tmp")
	err := rs.Apply()
	if err == nil {
		t.Error("Apply() with paths on non-Linux should return error")
	}
}
