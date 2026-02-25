package protocol

// NOTE: These types form the contract layer between Nexus and Mothership.
// Goal: keep stable, version-friendly, and easy to generate OpenAPI/JSON schema from.

type DirectiveSpec struct {
	DirectiveID    string       `json:"directive_id"`
	Facility       FacilitySpec `json:"facility"`
	SandboxProfile string       `json:"sandbox_profile"` // untrusted/trusted/host/darwin-automation etc

	Command string `json:"command"`         // shell command string (not JSON array)
	Shell   string `json:"shell,omitempty"` // default /bin/sh; unified across all platforms
	Cwd     string `json:"cwd,omitempty"`

	TimeoutSeconds int    `json:"timeout_seconds,omitempty"`
	Limits         Limits `json:"limits,omitempty"`

	Capabilities Capabilities `json:"capabilities,omitempty"`

	Artifacts ArtifactsSpec `json:"artifacts,omitempty"`
}

type FacilitySpec struct {
	ID      string `json:"id"`
	Mount   string `json:"mount,omitempty"`    // default /workspace
	RepoURL string `json:"repo_url,omitempty"` // supplement: clone hint for prepare stage (Decision D7/D8)
}

type Limits struct {
	CPU            int `json:"cpu,omitempty"`
	MemoryMB       int `json:"memory_mb,omitempty"`
	DiskMB         int `json:"disk_mb,omitempty"`
	MaxOutputBytes int `json:"max_output_bytes,omitempty"`
	MaxDiffBytes   int `json:"max_diff_bytes,omitempty"`
}

type Capabilities struct {
	Net *NetCapabilityV1 `json:"net,omitempty"`
	Fs  *FsCapabilityV1  `json:"fs,omitempty"`
	// TODO: env/secrets ...
}

type ArtifactsSpec struct {
	Collect    []string `json:"collect,omitempty"`
	AlwaysDiff bool     `json:"always_diff,omitempty"`
}

// NetCapabilityV1 corresponds to docs/protocol/directivespec_capabilities_net.schema.v1.json
type NetCapabilityV1 struct {
	Mode       string         `json:"mode"`                  // none/allowlist/unrestricted
	Preset     string         `json:"preset,omitempty"`      // off/loose/strict/no_external/custom
	Allow      []string       `json:"allow,omitempty"`       // required when mode=allowlist
	TTLSeconds int            `json:"ttl_seconds,omitempty"` // hint for audit (future: enforcement)
	XExt       map[string]any `json:"x_ext,omitempty"`
}

// FsCapabilityV1 corresponds to docs/protocol/directivespec_capabilities_fs.schema.v1.json
//
// Phase 1 fields (Read/Write): logical path selectors using workspace: prefix.
// Phase 2c additions (WritableRoots/ReadOnlySubpaths): host-absolute paths for
// Landlock enforcement. When both old and new fields are present, the new fields
// take precedence for enforcement; the old fields remain for audit/UI.
type FsCapabilityV1 struct {
	Read  []string `json:"read,omitempty"`
	Write []string `json:"write,omitempty"`

	// Phase 2c: Landlock-friendly absolute paths derived from policy resolution.
	// WritableRoots lists host-absolute directories where read+write is allowed.
	// ReadOnlySubpaths lists host-absolute directories where only read is allowed.
	WritableRoots    []string `json:"writable_roots,omitempty"`
	ReadOnlySubpaths []string `json:"read_only_subpaths,omitempty"`
}

type DirectiveLease struct {
	DirectiveID    string        `json:"directive_id"`
	DirectiveToken string        `json:"directive_token"`
	Spec           DirectiveSpec `json:"spec"`
}

type PollRequest struct {
	SupportedSandboxProfiles []string `json:"supported_sandbox_profiles"`
	MaxDirectivesToClaim     int      `json:"max_directives_to_claim,omitempty"`
}

type PollResponse struct {
	Directives        []DirectiveLease `json:"directives"`
	LeaseTTLSeconds   int              `json:"lease_ttl_seconds,omitempty"`
	RetryAfterSeconds int              `json:"retry_after_seconds,omitempty"`
}

// Nexus -> Mothership enrollment (Phase 0/0.5)
type EnrollRequest struct {
	EnrollToken string         `json:"enroll_token"`
	Name        string         `json:"name,omitempty"`
	Labels      map[string]any `json:"labels,omitempty"`
	Metadata    map[string]any `json:"metadata,omitempty"`
	CSRPEM      string         `json:"csr_pem,omitempty"`
}

type EnrollResponse struct {
	TerritoryID       string         `json:"territory_id"`
	MTLSClientCertPEM string         `json:"mtls_client_cert_pem,omitempty"`
	CABundlePEM       string         `json:"ca_bundle_pem,omitempty"`
	Config            map[string]any `json:"config"`
}

// TerritoryHeartbeatRequest is a territory-level presence heartbeat.
type TerritoryHeartbeatRequest struct {
	NexusVersion           string         `json:"nexus_version,omitempty"`
	RunningDirectivesCount *int           `json:"running_directives_count,omitempty"`
	Labels                 map[string]any `json:"labels,omitempty"`
	Capacity               map[string]any `json:"capacity,omitempty"`
	Telemetry              map[string]any `json:"telemetry,omitempty"`
}

type TerritoryHeartbeatResponse struct {
	OK          bool   `json:"ok"`
	TerritoryID string `json:"territory_id,omitempty"`

	// Version negotiation: informational fields from the server.
	UpgradeAvailable     bool   `json:"upgrade_available,omitempty"`
	LatestVersion        string `json:"latest_version,omitempty"`
	MinCompatibleVersion string `json:"min_compatible_version,omitempty"`
}

// Nexus -> Mothership lifecycle payloads (minimal V1)
type StartedRequest struct {
	EffectiveCapabilitiesSummary map[string]any `json:"effective_capabilities_summary,omitempty"`
	SandboxVersion               string         `json:"sandbox_version,omitempty"`
	NexusVersion                 string         `json:"nexus_version,omitempty"`
	RuntimeRef                   string         `json:"runtime_ref,omitempty"` // opaque driver reference (container ID, VM ID, etc.)
	StartedAt                    string         `json:"started_at,omitempty"`
}

type HeartbeatRequest struct {
	Progress      map[string]any `json:"progress,omitempty"`
	LastOutputSeq int            `json:"last_output_seq,omitempty"`
	Now           string         `json:"now,omitempty"`
}

type HeartbeatResponse struct {
	CancelRequested bool   `json:"cancel_requested,omitempty"`
	LeaseRenewed    bool   `json:"lease_renewed,omitempty"`
	DirectiveToken  string `json:"directive_token,omitempty"` // refreshed JWT; replaces the previous token
}

type LogChunkRequest struct {
	Stream      string `json:"stream"` // stdout/stderr
	Seq         int    `json:"seq"`
	BytesBase64 string `json:"bytes"` // base64
	Truncated   bool   `json:"truncated,omitempty"`
}

type FinishedRequest struct {
	ExitCode          *int           `json:"exit_code"` // pointer: 0 is valid, nil means not set
	Status            string         `json:"status"`    // succeeded/failed/canceled/timed_out
	StdoutTruncated   bool           `json:"stdout_truncated,omitempty"`
	StderrTruncated   bool           `json:"stderr_truncated,omitempty"`
	DiffTruncated     bool           `json:"diff_truncated,omitempty"`
	DiffBase64        string         `json:"diff_base64,omitempty"`     // base64-encoded diff blob
	SnapshotBefore    string         `json:"snapshot_before,omitempty"` // git HEAD hash before execution
	SnapshotAfter     string         `json:"snapshot_after,omitempty"`  // git HEAD hash after execution
	ArtifactsManifest map[string]any `json:"artifacts_manifest,omitempty"`
	FinishedAt        string         `json:"finished_at,omitempty"`
}
