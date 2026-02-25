//go:build !linux

package sandbox

import "cybros.ai/nexus/protocol"

// CgroupLimiter is a no-op on non-Linux platforms.
type CgroupLimiter struct{}

// ApplyCgroupLimits is a no-op on non-Linux platforms.
// Returns nil, nil — callers should check for nil limiter.
func ApplyCgroupLimits(_ string, _ int, _ protocol.Limits) (*CgroupLimiter, error) {
	return nil, nil
}

// Cleanup is a no-op on non-Linux platforms.
func (c *CgroupLimiter) Cleanup() {}
