package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type TLSConfig struct {
	// CAFile is a PEM bundle used to validate the control-plane server cert.
	CAFile string `yaml:"ca_file"`
	// ClientCertFile and ClientKeyFile are PEM files for mTLS client auth.
	ClientCertFile string `yaml:"client_cert_file"`
	ClientKeyFile  string `yaml:"client_key_file"`

	// InsecureSkipVerify is ONLY for local dev. Do not use in production.
	InsecureSkipVerify bool `yaml:"insecure_skip_verify"`
}

type PollConfig struct {
	// LongPollTimeout controls the HTTP client timeout for poll requests.
	LongPollTimeout time.Duration `yaml:"long_poll_timeout"`
	// RetryBackoff is used when the server returns no directives.
	RetryBackoff time.Duration `yaml:"retry_backoff"`
	// MaxDirectivesToClaim is the maximum number of directives to request per poll.
	MaxDirectivesToClaim int `yaml:"max_directives_to_claim"`
}

type LogConfig struct {
	// MaxOutputBytes is a hard cap for combined stdout+stderr for a directive (best-effort).
	MaxOutputBytes int64 `yaml:"max_output_bytes"`
	// ChunkBytes controls the size of each log_chunk upload.
	ChunkBytes int `yaml:"chunk_bytes"`
}

type LogOverflowConfig struct {
	// Enabled writes stdout/stderr overflow beyond MaxOutputBytes to disk.
	Enabled bool `yaml:"enabled"`

	// Dir is a workspace-relative directory (within the facility) for overflow files.
	// Default: ".nexus/overflow"
	Dir string `yaml:"dir"`

	// MaxBytesPerStream caps the on-disk overflow size per stream.
	MaxBytesPerStream int64 `yaml:"max_bytes_per_stream"`
}

type DebugTapeConfig struct {
	// Enabled writes a local JSONL tape for offline debugging.
	Enabled bool `yaml:"enabled"`

	// Path is the output file path for the tape (JSONL).
	Path string `yaml:"path"`

	// MaxBytes triggers a simple rotation to "<path>.1" when exceeded.
	MaxBytes int64 `yaml:"max_bytes"`
}

type HeartbeatConfig struct {
	// Interval controls how often Nexus sends heartbeats during execution.
	Interval time.Duration `yaml:"interval"`
}

type TerritoryHeartbeatConfig struct {
	// Interval controls how often Nexus sends territory-level presence heartbeats.
	Interval time.Duration `yaml:"interval"`
}

type RootfsArchSourceConfig struct {
	URL    string `yaml:"url"`
	SHA256 string `yaml:"sha256"`
}

type RootfsConfig struct {
	// Auto enables automatic download+verification+extraction of the pinned Ubuntu 24.04 minimal rootfs.
	Auto bool `yaml:"auto"`

	// CacheDir is where downloaded archives and extracted rootfs trees are stored.
	CacheDir string `yaml:"cache_dir"`

	// Arch-specific sources (selected by GOARCH).
	AMD64 RootfsArchSourceConfig `yaml:"amd64"`
	ARM64 RootfsArchSourceConfig `yaml:"arm64"`
}

// BwrapConfig holds bubblewrap sandbox driver settings (Linux only).
type BwrapConfig struct {
	// BwrapPath is the path to the bubblewrap binary. Default: "bwrap" (PATH lookup).
	BwrapPath string `yaml:"bwrap_path"`
	// SocatPath is the path to the socat binary. Default: "socat" (PATH lookup).
	SocatPath string `yaml:"socat_path"`
	// RootfsPath is an optional read-only rootfs to use instead of host /.
	// Empty means use the host filesystem.
	RootfsPath string `yaml:"rootfs_path"`
	// ProxySocketDir is where per-directive proxy UDS files are created.
	// Empty means <work_dir>/.proxy-sockets/
	ProxySocketDir string `yaml:"proxy_socket_dir"`
}

// FirecrackerConfig holds Firecracker microVM sandbox driver settings (Linux only).
type FirecrackerConfig struct {
	// FirecrackerPath is the path to the firecracker binary. Default: "firecracker" (PATH lookup).
	FirecrackerPath string `yaml:"firecracker_path"`
	// KernelPath is the path to the guest vmlinux kernel.
	KernelPath string `yaml:"kernel_path"`
	// RootfsImagePath is the path to the base ext4 rootfs image.
	RootfsImagePath string `yaml:"rootfs_image_path"`
	// VCPUs is the number of virtual CPUs for the microVM. Default: 2.
	VCPUs int `yaml:"vcpus"`
	// MemSizeMiB is the memory size in MiB for the microVM. Default: 512.
	MemSizeMiB int `yaml:"mem_size_mib"`
	// WorkspaceSizeMiB is the maximum ext4 workspace image size in MiB. Default: 2048.
	WorkspaceSizeMiB int `yaml:"workspace_size_mib"`
	// ProxySocketDir is where per-directive proxy UDS files are created.
	// Empty means <work_dir>/.proxy-sockets/
	ProxySocketDir string `yaml:"proxy_socket_dir"`
}

// ContainerConfig holds container sandbox driver settings (Linux only).
type ContainerConfig struct {
	// Runtime is the container runtime executable. Default: "podman".
	Runtime string `yaml:"runtime"`
	// Image is the container image to use. Default: "ubuntu:24.04".
	Image string `yaml:"image"`
	// ProxyMode controls how network proxy is configured: "env" or "none".
	// Default: "env" (inject HTTP_PROXY/HTTPS_PROXY environment variables).
	ProxyMode string `yaml:"proxy_mode"`
}

// ObservabilityConfig controls the built-in HTTP health/metrics server.
type ObservabilityConfig struct {
	// Enabled starts the observability HTTP server.
	Enabled bool `yaml:"enabled"`
	// ListenAddr is the address for the health/metrics server (e.g. ":9090").
	ListenAddr string `yaml:"listen_addr"`
}

type Config struct {
	ServerURL   string            `yaml:"server_url"`
	TerritoryID string            `yaml:"territory_id"`
	Name        string            `yaml:"name"`
	Labels      map[string]string `yaml:"labels"`

	WorkDir string `yaml:"work_dir"`

	TLS                TLSConfig                `yaml:"tls"`
	Poll               PollConfig               `yaml:"poll"`
	Log                LogConfig                `yaml:"log"`
	LogOverflow        LogOverflowConfig        `yaml:"log_overflow"`
	DebugTape          DebugTapeConfig          `yaml:"debug_tape"`
	Heartbeat          HeartbeatConfig          `yaml:"heartbeat"`
	TerritoryHeartbeat TerritoryHeartbeatConfig `yaml:"territory_heartbeat"`
	Observability      ObservabilityConfig      `yaml:"observability"`

	// ShutdownTimeout is the maximum time to wait for in-flight directives
	// during graceful shutdown. Default: 60s. Zero means wait indefinitely.
	ShutdownTimeout time.Duration `yaml:"shutdown_timeout"`

	Rootfs RootfsConfig `yaml:"rootfs"`

	Bwrap       BwrapConfig       `yaml:"bwrap"`
	Container   ContainerConfig   `yaml:"container"`
	Firecracker FirecrackerConfig `yaml:"firecracker"`

	// UntrustedDriver selects the driver for the "untrusted" sandbox profile.
	// Valid values: "bwrap" (default), "firecracker".
	UntrustedDriver string `yaml:"untrusted_driver"`

	SupportedSandboxProfiles []string `yaml:"supported_sandbox_profiles"`
}

func Default() Config {
	return Config{
		ServerURL:   "http://localhost:3000",
		TerritoryID: "",
		Name:        "nexus",
		Labels:      map[string]string{},
		WorkDir:     "./facilities",
		TLS:         TLSConfig{},
		Poll: PollConfig{
			LongPollTimeout:      25 * time.Second,
			RetryBackoff:         2 * time.Second,
			MaxDirectivesToClaim: 1,
		},
		Log: LogConfig{
			MaxOutputBytes: 2_000_000,
			ChunkBytes:     16 * 1024,
		},
		LogOverflow: LogOverflowConfig{
			Enabled:           true,
			Dir:               ".nexus/overflow",
			MaxBytesPerStream: 50 * 1024 * 1024, // 50 MiB
		},
		DebugTape: DebugTapeConfig{
			Enabled:  false,
			Path:     "./nexus-debug-tape.jsonl",
			MaxBytes: 10 * 1024 * 1024, // 10 MiB
		},
		Heartbeat: HeartbeatConfig{
			Interval: 10 * time.Second,
		},
		TerritoryHeartbeat: TerritoryHeartbeatConfig{
			Interval: 30 * time.Second,
		},
		Observability: ObservabilityConfig{
			Enabled:    false,
			ListenAddr: ":9090",
		},
		ShutdownTimeout: 60 * time.Second,
		Rootfs: RootfsConfig{
			Auto:     false,
			CacheDir: "./rootfs-cache",
			AMD64: RootfsArchSourceConfig{
				URL:    "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64-root.tar.xz",
				SHA256: "4119418996553edb37307a5ee3a3bd6d754ab28a37f5df057aa2b6551e87d417",
			},
			ARM64: RootfsArchSourceConfig{
				URL:    "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64-root.tar.xz",
				SHA256: "eb50d09466a96381bd1bd68d2a78f2c55be2b6d0256c5df323a35992c180e8ff",
			},
		},
		Bwrap: BwrapConfig{
			BwrapPath: "bwrap",
			SocatPath: "socat",
		},
		Container: ContainerConfig{
			Runtime:   "podman",
			Image:     "ubuntu:24.04",
			ProxyMode: "env",
		},
		Firecracker: FirecrackerConfig{
			FirecrackerPath:  "firecracker",
			VCPUs:            2,
			MemSizeMiB:       512,
			WorkspaceSizeMiB: 2048,
		},
		UntrustedDriver:          "bwrap",
		SupportedSandboxProfiles: []string{"host"},
	}
}

func LoadFile(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	// Expand ${ENV_VAR} references before parsing YAML,
	// enabling containerized deployments to inject secrets/config.
	expanded := os.ExpandEnv(string(b))
	cfg := Default()
	if err := yaml.Unmarshal([]byte(expanded), &cfg); err != nil {
		return Config{}, fmt.Errorf("parse config yaml: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
	if c.ServerURL == "" {
		return errors.New("server_url is required")
	}
	if c.TerritoryID == "" {
		// Allow empty in early dev mode, but warn at runtime.
	}
	if c.Poll.MaxDirectivesToClaim <= 0 {
		return errors.New("poll.max_directives_to_claim must be >= 1")
	}
	if c.Log.ChunkBytes <= 0 {
		return errors.New("log.chunk_bytes must be >= 1")
	}
	if c.Log.MaxOutputBytes <= 0 {
		return errors.New("log.max_output_bytes must be >= 1")
	}

	if c.LogOverflow.Enabled {
		if c.LogOverflow.Dir == "" {
			return errors.New("log_overflow.dir is required when enabled")
		}
		if filepath.IsAbs(c.LogOverflow.Dir) {
			return errors.New("log_overflow.dir must be workspace-relative (not an absolute path)")
		}
		clean := filepath.Clean(c.LogOverflow.Dir)
		if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return errors.New("log_overflow.dir must be within the workspace")
		}
		if c.LogOverflow.MaxBytesPerStream <= 0 {
			return errors.New("log_overflow.max_bytes_per_stream must be >= 1 when enabled")
		}
	}

	if c.DebugTape.Enabled {
		if c.DebugTape.Path == "" {
			return errors.New("debug_tape.path is required when enabled")
		}
		if c.DebugTape.MaxBytes <= 0 {
			return errors.New("debug_tape.max_bytes must be >= 1 when enabled")
		}
	}

	switch c.UntrustedDriver {
	case "", "bwrap", "firecracker":
		// valid
	default:
		return fmt.Errorf("untrusted_driver must be \"bwrap\" or \"firecracker\", got %q", c.UntrustedDriver)
	}

	if c.UntrustedDriver == "firecracker" {
		if c.Firecracker.KernelPath == "" {
			return errors.New("firecracker.kernel_path is required when untrusted_driver is firecracker")
		}
		if c.Firecracker.RootfsImagePath == "" {
			return errors.New("firecracker.rootfs_image_path is required when untrusted_driver is firecracker")
		}
		if c.Firecracker.VCPUs <= 0 {
			return errors.New("firecracker.vcpus must be >= 1")
		}
		if c.Firecracker.MemSizeMiB <= 0 {
			return errors.New("firecracker.mem_size_mib must be >= 1")
		}
		if c.Firecracker.WorkspaceSizeMiB <= 0 {
			return errors.New("firecracker.workspace_size_mib must be >= 1")
		}
		if c.Firecracker.WorkspaceSizeMiB > 32768 {
			return errors.New("firecracker.workspace_size_mib must be <= 32768 (32 GiB)")
		}
	}

	if c.Rootfs.Auto {
		if c.Rootfs.CacheDir == "" {
			return errors.New("rootfs.cache_dir is required when rootfs.auto is enabled")
		}

		var src RootfsArchSourceConfig
		switch runtime.GOARCH {
		case "amd64":
			src = c.Rootfs.AMD64
		case "arm64":
			src = c.Rootfs.ARM64
		default:
			return fmt.Errorf("rootfs.auto is not supported on GOARCH=%s", runtime.GOARCH)
		}

		if src.URL == "" || src.SHA256 == "" {
			return errors.New("rootfs arch source must specify url and sha256")
		}
	}

	return nil
}
