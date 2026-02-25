package sandbox

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

// ResolveWorkspaceCwd resolves a requested CWD path relative to the workspace root.
// It ensures the result is always within workDir (path traversal prevention).
//
// Mapping rules:
//   - "", ".", "/workspace" → workDir
//   - "/workspace/sub/dir"  → workDir/sub/dir
//   - "sub/dir" (relative)  → workDir/sub/dir
//   - "/etc" (abs outside)  → error
//   - "../escape"           → error
func ResolveWorkspaceCwd(workDir string, requested string) (string, error) {
	if workDir == "" {
		return "", errors.New("work dir is required")
	}

	if requested == "" || requested == "." || requested == "/workspace" {
		return workDir, nil
	}

	cleaned := filepath.Clean(requested)

	if filepath.IsAbs(cleaned) {
		if cleaned == "/workspace" {
			return workDir, nil
		}
		if strings.HasPrefix(cleaned, "/workspace/") {
			return SafeJoin(workDir, strings.TrimPrefix(cleaned, "/workspace/"))
		}
		return "", fmt.Errorf("cwd must be under /workspace")
	}

	return SafeJoin(workDir, cleaned)
}

// SafeJoin joins base and rel, then verifies the result does not escape base.
// Returns an error if the resulting path is outside the base directory.
func SafeJoin(base string, rel string) (string, error) {
	target := filepath.Join(base, rel)
	relToBase, err := filepath.Rel(base, target)
	if err != nil {
		return "", err
	}
	if relToBase == "." {
		return target, nil
	}
	if relToBase == ".." || strings.HasPrefix(relToBase, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("cwd escapes workspace")
	}
	return target, nil
}
