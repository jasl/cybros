package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// baseValidConfig returns a Config that passes all validation.
func baseValidConfig() Config {
	cfg := Default()
	cfg.ServerURL = "http://localhost:3000"
	return cfg
}

// --- Default ---

func TestDefault_HasSensibleValues(t *testing.T) {
	t.Parallel()

	cfg := Default()
	if cfg.ServerURL != "http://localhost:3000" {
		t.Errorf("expected default ServerURL, got %q", cfg.ServerURL)
	}
	if cfg.Poll.MaxDirectivesToClaim != 1 {
		t.Errorf("expected MaxDirectivesToClaim=1, got %d", cfg.Poll.MaxDirectivesToClaim)
	}
	if cfg.Log.ChunkBytes <= 0 {
		t.Error("expected positive ChunkBytes")
	}
	if cfg.Log.MaxOutputBytes <= 0 {
		t.Error("expected positive MaxOutputBytes")
	}
	if cfg.UntrustedDriver != "bwrap" {
		t.Errorf("expected default UntrustedDriver=bwrap, got %q", cfg.UntrustedDriver)
	}
}

func TestDefault_Validates(t *testing.T) {
	t.Parallel()

	cfg := Default()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Default() should validate: %v", err)
	}
}

// --- LoadFile ---

func TestLoadFile_ValidYAML(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "config.yml")
	yaml := `
server_url: "https://example.com"
territory_id: "t-1"
work_dir: "/tmp/facilities"
`
	if err := os.WriteFile(path, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadFile(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.ServerURL != "https://example.com" {
		t.Fatalf("expected server_url override, got %q", cfg.ServerURL)
	}
	if cfg.TerritoryID != "t-1" {
		t.Fatalf("expected territory_id override, got %q", cfg.TerritoryID)
	}
	// Defaults should be preserved for unset fields.
	if cfg.Poll.MaxDirectivesToClaim != 1 {
		t.Fatalf("expected default MaxDirectivesToClaim preserved, got %d", cfg.Poll.MaxDirectivesToClaim)
	}
}

func TestLoadFile_NonexistentFile(t *testing.T) {
	t.Parallel()

	_, err := LoadFile("/nonexistent/config.yml")
	if err == nil {
		t.Fatal("expected error for nonexistent file")
	}
}

func TestLoadFile_InvalidYAML(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "bad.yml")
	if err := os.WriteFile(path, []byte("{{invalid yaml"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := LoadFile(path)
	if err == nil {
		t.Fatal("expected error for invalid YAML")
	}
}

func TestLoadFile_ValidationFailure(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "bad.yml")
	yaml := `
server_url: ""
`
	if err := os.WriteFile(path, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := LoadFile(path)
	if err == nil {
		t.Fatal("expected validation error for empty server_url")
	}
}

// --- Validate ---

func TestValidate_EmptyServerURL(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.ServerURL = ""
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for empty server_url")
	}
	if !strings.Contains(err.Error(), "server_url") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_MaxDirectivesToClaim(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.Poll.MaxDirectivesToClaim = 0
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for MaxDirectivesToClaim=0")
	}
	if !strings.Contains(err.Error(), "max_directives_to_claim") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_LogChunkBytes(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.Log.ChunkBytes = 0
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for ChunkBytes=0")
	}
	if !strings.Contains(err.Error(), "chunk_bytes") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_LogMaxOutputBytes(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.Log.MaxOutputBytes = -1
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for MaxOutputBytes=-1")
	}
	if !strings.Contains(err.Error(), "max_output_bytes") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_LogOverflow_EmptyDir(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.LogOverflow.Enabled = true
	cfg.LogOverflow.Dir = ""
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for empty LogOverflow.Dir")
	}
}

func TestValidate_LogOverflow_AbsoluteDir(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.LogOverflow.Enabled = true
	cfg.LogOverflow.Dir = "/etc/overflow"
	cfg.LogOverflow.MaxBytesPerStream = 1024
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for absolute LogOverflow.Dir")
	}
	if !strings.Contains(err.Error(), "workspace-relative") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_LogOverflow_ParentEscape(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.LogOverflow.Enabled = true
	cfg.LogOverflow.Dir = "../escape"
	cfg.LogOverflow.MaxBytesPerStream = 1024
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for LogOverflow.Dir escaping workspace")
	}
	if !strings.Contains(err.Error(), "within the workspace") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_LogOverflow_ZeroMaxBytes(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.LogOverflow.Enabled = true
	cfg.LogOverflow.Dir = ".nexus/overflow"
	cfg.LogOverflow.MaxBytesPerStream = 0
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for MaxBytesPerStream=0")
	}
}

func TestValidate_LogOverflow_DisabledSkipsValidation(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.LogOverflow.Enabled = false
	cfg.LogOverflow.Dir = "" // would fail if enabled
	err := cfg.Validate()
	if err != nil {
		t.Fatalf("disabled LogOverflow should skip validation: %v", err)
	}
}

func TestValidate_DebugTape_EmptyPath(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.DebugTape.Enabled = true
	cfg.DebugTape.Path = ""
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for empty DebugTape.Path")
	}
}

func TestValidate_DebugTape_ZeroMaxBytes(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.DebugTape.Enabled = true
	cfg.DebugTape.Path = "/tmp/tape.jsonl"
	cfg.DebugTape.MaxBytes = 0
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for DebugTape.MaxBytes=0")
	}
}

func TestValidate_DebugTape_DisabledSkipsValidation(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.DebugTape.Enabled = false
	cfg.DebugTape.Path = "" // would fail if enabled
	err := cfg.Validate()
	if err != nil {
		t.Fatalf("disabled DebugTape should skip validation: %v", err)
	}
}

func TestValidate_RootfsAuto_EmptyCacheDir(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.Rootfs.Auto = true
	cfg.Rootfs.CacheDir = ""
	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for empty Rootfs.CacheDir")
	}
}

func TestValidate_RootfsAuto_MissingArchSource(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.Rootfs.Auto = true
	cfg.Rootfs.CacheDir = "/tmp/cache"
	// Clear the current arch source to trigger validation.
	cfg.Rootfs.AMD64 = RootfsArchSourceConfig{}
	cfg.Rootfs.ARM64 = RootfsArchSourceConfig{}

	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for missing rootfs arch source")
	}
}

// --- Firecracker validation (existing tests, restructured) ---

func TestValidate_FirecrackerRequiresKernelPath(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.UntrustedDriver = "firecracker"
	cfg.Firecracker.KernelPath = ""
	cfg.Firecracker.RootfsImagePath = "/rootfs.ext4"

	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected validation error for missing kernel_path")
	}
	if !strings.Contains(err.Error(), "kernel_path") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_FirecrackerRequiresRootfsPath(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.UntrustedDriver = "firecracker"
	cfg.Firecracker.KernelPath = "/vmlinux"
	cfg.Firecracker.RootfsImagePath = ""

	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected validation error for missing rootfs_image_path")
	}
	if !strings.Contains(err.Error(), "rootfs_image_path") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_FirecrackerWorkspaceSizeUpperBound(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.UntrustedDriver = "firecracker"
	cfg.Firecracker.KernelPath = "/vmlinux"
	cfg.Firecracker.RootfsImagePath = "/rootfs.ext4"
	cfg.Firecracker.WorkspaceSizeMiB = 32769

	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected validation error for workspace_size_mib > 32768")
	}
	if !strings.Contains(err.Error(), "32768") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_FirecrackerValidConfig(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.UntrustedDriver = "firecracker"
	cfg.Firecracker.KernelPath = "/vmlinux"
	cfg.Firecracker.RootfsImagePath = "/rootfs.ext4"
	cfg.Firecracker.VCPUs = 2
	cfg.Firecracker.MemSizeMiB = 512
	cfg.Firecracker.WorkspaceSizeMiB = 2048

	err := cfg.Validate()
	if err != nil {
		t.Fatalf("unexpected validation error: %v", err)
	}
}

func TestValidate_InvalidUntrustedDriver(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.UntrustedDriver = "docker"

	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected validation error for invalid untrusted_driver")
	}
	if !strings.Contains(err.Error(), "untrusted_driver") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestValidate_BwrapSkipsFirecrackerValidation(t *testing.T) {
	t.Parallel()

	cfg := baseValidConfig()
	cfg.UntrustedDriver = "bwrap"
	cfg.Firecracker.KernelPath = ""
	cfg.Firecracker.RootfsImagePath = ""

	err := cfg.Validate()
	if err != nil {
		t.Fatalf("bwrap mode should not validate firecracker config: %v", err)
	}
}

// --- Env var substitution ---

func TestLoadFile_EnvVarSubstitution(t *testing.T) {
	// Not parallel: t.Setenv modifies process environment.
	t.Setenv("NEXUS_TEST_SERVER", "https://env.example.com")
	t.Setenv("NEXUS_TEST_TERRITORY", "t-env-42")

	dir := t.TempDir()
	path := filepath.Join(dir, "config.yml")
	yaml := `
server_url: "${NEXUS_TEST_SERVER}"
territory_id: "${NEXUS_TEST_TERRITORY}"
work_dir: "/tmp/facilities"
`
	if err := os.WriteFile(path, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadFile(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.ServerURL != "https://env.example.com" {
		t.Errorf("expected env-expanded server_url, got %q", cfg.ServerURL)
	}
	if cfg.TerritoryID != "t-env-42" {
		t.Errorf("expected env-expanded territory_id, got %q", cfg.TerritoryID)
	}
}

func TestLoadFile_EnvVarUnset(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "config.yml")
	// Unset env var expands to empty string.
	yaml := `
server_url: "https://example.com"
territory_id: "${NEXUS_NONEXISTENT_VAR_12345}"
work_dir: "/tmp/facilities"
`
	if err := os.WriteFile(path, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadFile(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.TerritoryID != "" {
		t.Errorf("expected empty territory_id for unset var, got %q", cfg.TerritoryID)
	}
}
