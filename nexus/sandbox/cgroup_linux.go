//go:build linux

package sandbox

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strconv"

	"cybros.ai/nexus/protocol"
)

const cgroupBase = "/sys/fs/cgroup/nexusd"

// maxCPUMillicores caps the CPU limit to prevent integer overflow.
const maxCPUMillicores = 1024000 // 1024 cores

// maxMemoryMB caps the memory limit to prevent integer overflow.
const maxMemoryMB = 1 << 20 // 1 TiB

// validCgroupIDRe ensures the directive ID is safe for use as a cgroup path component.
var validCgroupIDRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)

// CgroupLimiter applies cgroup v2 resource limits to a process.
type CgroupLimiter struct {
	path string // e.g. /sys/fs/cgroup/nexusd/<directive-id>
}

// ApplyCgroupLimits creates a cgroup v2 slice for the given directive,
// writes memory and CPU limits, and adds the process to it.
// Returns a CgroupLimiter that must be cleaned up after the directive finishes.
// If limits are zero, those constraints are not applied.
func ApplyCgroupLimits(directiveID string, pid int, limits protocol.Limits) (*CgroupLimiter, error) {
	if limits.CPU <= 0 && limits.MemoryMB <= 0 {
		return nil, nil
	}

	// Validate directive ID to prevent path traversal (defense in depth).
	if !validCgroupIDRe.MatchString(directiveID) {
		return nil, fmt.Errorf("invalid directive ID for cgroup: %q", directiveID)
	}

	// Bounds check to prevent integer overflow.
	if limits.CPU > maxCPUMillicores {
		return nil, fmt.Errorf("CPU limit %d exceeds maximum %d millicores", limits.CPU, maxCPUMillicores)
	}
	if limits.MemoryMB > maxMemoryMB {
		return nil, fmt.Errorf("memory limit %d MB exceeds maximum %d MB", limits.MemoryMB, maxMemoryMB)
	}

	cgPath := filepath.Join(cgroupBase, directiveID)
	if err := os.MkdirAll(cgPath, 0o700); err != nil {
		return nil, fmt.Errorf("create cgroup dir: %w", err)
	}

	limiter := &CgroupLimiter{path: cgPath}

	if limits.MemoryMB > 0 {
		memBytes := int64(limits.MemoryMB) * 1024 * 1024
		if err := os.WriteFile(filepath.Join(cgPath, "memory.max"), []byte(strconv.FormatInt(memBytes, 10)), 0o644); err != nil {
			limiter.Cleanup()
			return nil, fmt.Errorf("write memory.max: %w", err)
		}
	}

	if limits.CPU > 0 {
		// cpu.max format: "$QUOTA $PERIOD" — e.g. "100000 100000" = 1 core
		// CPU field is in millicores (1000 = 1 core), period is 100ms.
		period := 100000
		quota := (limits.CPU * period) / 1000
		if quota < 1000 {
			quota = 1000 // minimum 1ms quota
		}
		val := fmt.Sprintf("%d %d", quota, period)
		if err := os.WriteFile(filepath.Join(cgPath, "cpu.max"), []byte(val), 0o644); err != nil {
			limiter.Cleanup()
			return nil, fmt.Errorf("write cpu.max: %w", err)
		}
	}

	// Add process to cgroup.
	if err := os.WriteFile(filepath.Join(cgPath, "cgroup.procs"), []byte(strconv.Itoa(pid)), 0o644); err != nil {
		limiter.Cleanup()
		return nil, fmt.Errorf("write cgroup.procs: %w", err)
	}

	slog.Info("cgroup limits applied",
		"directive_id", directiveID,
		"cgroup_path", cgPath,
		"memory_mb", limits.MemoryMB,
		"cpu_millicores", limits.CPU,
	)

	return limiter, nil
}

// Cleanup removes the cgroup directory. The cgroup must have no running
// processes; the kernel will reject rmdir otherwise.
func (c *CgroupLimiter) Cleanup() {
	if c == nil {
		return
	}
	if err := os.Remove(c.path); err != nil {
		slog.Warn("cgroup cleanup failed (processes may still be running)",
			"path", c.path, "error", err)
	}
}
