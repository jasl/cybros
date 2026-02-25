package sandbox

import (
	"context"
	"io"

	"cybros.ai/nexus/protocol"
)

// Driver is the interface that all sandbox drivers must implement.
type Driver interface {
	Name() string
	Run(ctx context.Context, req RunRequest) (RunResult, error)

	// HealthCheck verifies that the driver's dependencies are available
	// and functional. Called periodically by the territory heartbeat loop
	// and before each directive assignment.
	HealthCheck(ctx context.Context) HealthResult
}

// HealthResult reports the health status of a sandbox driver.
type HealthResult struct {
	Healthy bool              `json:"healthy"`
	Details map[string]string `json:"details,omitempty"`
}

type RunRequest struct {
	DirectiveID string

	Command string // shell command string
	Shell   string // default /bin/sh
	Cwd     string

	// Env is additional env vars (in addition to inherited process env if desired).
	Env map[string]string

	// WorkDir is the workspace root path on the host filesystem.
	WorkDir string

	TimeoutSeconds int

	MaxOutputBytes int64
	ChunkBytes     int

	LogSink LogSink

	// Phase 1 additions: capability plumbing for sandbox drivers

	// NetCapability describes the network policy for this directive.
	// nil means deny-all. The host driver ignores this (no enforcement).
	NetCapability *protocol.NetCapabilityV1

	// FsCapability describes the filesystem access policy for this directive.
	// nil means use driver defaults (typically workspace-only).
	// Phase 2c: plumbed for Landlock enforcement on Linux.
	FsCapability *protocol.FsCapabilityV1

	// RepoURL triggers facility preparation (git clone) inside the sandbox.
	// Empty means the facility is already prepared or no repo needed.
	RepoURL string

	// FacilityPath is the absolute host-side path to the facility directory.
	// Used by bwrap/container drivers to bind-mount into the sandbox.
	FacilityPath string

	// Limits contains resource limits (CPU, memory) from the directive spec.
	// Used by host/bwrap drivers to apply cgroup v2 constraints on Linux.
	Limits protocol.Limits
}

type LogSink interface {
	Consume(ctx context.Context, stream string, r io.Reader) error
}

type RunResult struct {
	ExitCode int
	Status   string // succeeded/failed/canceled/timed_out

	StdoutTruncated bool
	StderrTruncated bool

	// Warnings are non-fatal issues that occurred during execution
	// (e.g., workspace extraction failure). Logged but do not change status.
	Warnings []string
	// TODO: artifacts_manifest, diff_ref, resource usage
}
