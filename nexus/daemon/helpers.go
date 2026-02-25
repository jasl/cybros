package daemon

import (
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/logstream"
	"cybros.ai/nexus/protocol"
)

// minDiskBytes is the minimum free disk space required to accept a directive.
// If available space drops below this threshold, the directive is rejected
// immediately with a clear error rather than risking a mid-execution failure.
const minDiskBytes = 1 << 30 // 1 GiB

// checkDiskSpace returns the available bytes on the filesystem containing path.
// Returns an error only if the stat call itself fails.
func checkDiskSpace(p string) (uint64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(p, &stat); err != nil {
		return 0, err
	}
	return stat.Bavail * uint64(stat.Bsize), nil
}

// isValidFacilityID checks that a facility ID is safe to use as a directory name.
// Rejects empty strings, path traversal components, and non-alphanumeric/dash/underscore characters.
func isValidFacilityID(id string) bool {
	if id == "" {
		return false
	}
	if id == "." || id == ".." || strings.Contains(id, "/") || strings.Contains(id, string(filepath.Separator)) {
		return false
	}
	for _, r := range id {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_') {
			return false
		}
	}
	return true
}

// buildDirectiveEnv creates the standard environment variables injected into every directive.
func buildDirectiveEnv(cfg config.Config, directiveID string, spec protocol.DirectiveSpec) map[string]string {
	locale := "C.UTF-8"
	if runtime.GOOS == "darwin" {
		locale = "en_US.UTF-8"
	}

	env := map[string]string{
		// Output stability / non-interactive defaults
		"NO_COLOR":  "1",
		"TERM":      "dumb",
		"LANG":      locale,
		"LC_ALL":    locale,
		"PAGER":     "cat",
		"GIT_PAGER": "cat",

		// Marker for in-sandbox tooling
		"CYBROS_NEXUS": "1",

		// Standard Cybros-injected variables
		"CYBROS_DIRECTIVE_ID":    directiveID,
		"CYBROS_FACILITY_ID":     spec.Facility.ID,
		"CYBROS_TERRITORY_ID":    cfg.TerritoryID,
		"CYBROS_SANDBOX_PROFILE": spec.SandboxProfile,
		"CYBROS_WORKSPACE":       spec.Facility.Mount,

		// Conventional CI-like variable
		"CI": "true",
	}

	return env
}

// minimalExecEnv returns a reduced environment for child processes to avoid
// leaking host secrets (API keys, tokens, etc.) into commands Nexus runs.
func minimalExecEnv() []string {
	locale := "C.UTF-8"
	if runtime.GOOS == "darwin" {
		locale = "en_US.UTF-8"
	}

	keys := []string{
		"PATH", "HOME", "USER", "LOGNAME", "SHELL",
		"TMPDIR", "SSH_AUTH_SOCK",
	}

	env := make([]string, 0, len(keys)+2)
	for _, key := range keys {
		if v := os.Getenv(key); v != "" {
			env = append(env, key+"="+v)
		}
	}

	env = append(env, "LANG="+locale, "LC_ALL="+locale)
	return env
}

func (s *Service) recordTape(event string, directiveID string, spec protocol.DirectiveSpec, driver string, profile string, detail any) {
	if s.tape == nil {
		return
	}
	s.tape.Record(tapeLine{
		DirectiveID: directiveID,
		FacilityID:  spec.Facility.ID,
		Profile:     profile,
		Driver:      driver,
		Event:       event,
		Detail:      detail,
	})
}

func buildLogOverflowManifest(spec protocol.DirectiveSpec, directiveID string, cfg config.LogOverflowConfig, uploader *logstream.Uploader) map[string]any {
	if uploader == nil {
		return nil
	}

	info := uploader.OverflowInfo()
	if !info.Enabled {
		return nil
	}
	if !uploader.StdoutTruncated() && !uploader.StderrTruncated() {
		return nil
	}

	mount := spec.Facility.Mount
	if mount == "" {
		mount = "/workspace"
	}

	dir := filepath.ToSlash(cfg.Dir)
	return map[string]any{
		"stdout_path":          path.Clean(path.Join(mount, dir, directiveID, "stdout.log")),
		"stderr_path":          path.Clean(path.Join(mount, dir, directiveID, "stderr.log")),
		"stdout_bytes":         info.StdoutBytes,
		"stderr_bytes":         info.StderrBytes,
		"max_bytes_per_stream": info.MaxBytesPerStream,
	}
}
