package landlock

import (
	"cybros.ai/nexus/protocol"
)

// FromFsCapability builds a Ruleset from a protocol.FsCapabilityV1.
//
// If the capability specifies WritableRoots/ReadOnlySubpaths (Phase 2c),
// those are used directly. Otherwise falls back to workDir-based defaults.
//
// Standard system paths (/usr, /lib, /etc, /proc, /dev, /tmp) are always
// added as read-only to keep the process functional.
func FromFsCapability(cap *protocol.FsCapabilityV1, workDir string) *Ruleset {
	rs := NewRuleset()

	if cap != nil && (len(cap.WritableRoots) > 0 || len(cap.ReadOnlySubpaths) > 0) {
		// Phase 2c explicit paths from policy resolution
		rs.AddWritable(cap.WritableRoots...)
		rs.AddReadOnly(cap.ReadOnlySubpaths...)
	} else {
		// Default: workspace is writable
		if workDir != "" {
			rs.AddWritable(workDir)
		}
	}

	// Always allow read access to essential system paths
	rs.AddReadOnly(systemReadOnlyPaths()...)

	return rs
}

// systemReadOnlyPaths returns common Linux system paths that must be readable
// for a process to function (dynamic linker, shared libraries, timezone, etc.).
func systemReadOnlyPaths() []string {
	return []string{
		"/usr",
		"/lib",
		"/lib64",
		"/etc",
		"/proc",
		"/dev",
		"/tmp",
		"/run",
	}
}
