//go:build !linux

package landlock

import "fmt"

// Ruleset is a no-op on non-Linux platforms.
type Ruleset struct {
	writablePaths  []string
	readOnlyPaths  []string
}

// NewRuleset creates an empty ruleset (no-op on non-Linux).
func NewRuleset() *Ruleset {
	return &Ruleset{}
}

// AddWritable is a no-op on non-Linux.
func (rs *Ruleset) AddWritable(paths ...string) {
	rs.writablePaths = append(rs.writablePaths, paths...)
}

// AddReadOnly is a no-op on non-Linux.
func (rs *Ruleset) AddReadOnly(paths ...string) {
	rs.readOnlyPaths = append(rs.readOnlyPaths, paths...)
}

// Available always returns false on non-Linux.
func Available() bool {
	return false
}

// Apply returns an error on non-Linux — Landlock is Linux-only.
// Callers should check Available() first.
func (rs *Ruleset) Apply() error {
	if len(rs.writablePaths) == 0 && len(rs.readOnlyPaths) == 0 {
		return nil // noop
	}
	return fmt.Errorf("landlock: not available on this platform")
}
