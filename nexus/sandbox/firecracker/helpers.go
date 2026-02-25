package firecracker

import (
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
)

// exitCodeCapture is an io.Writer that scans serial output for a per-execution
// exit code marker. The marker includes a random nonce to prevent guest commands
// from spoofing exit codes (the guest cannot predict the nonce).
//
// It handles data arriving in arbitrary chunks by buffering partial lines.
// Only the last matching line is kept to prevent unbounded memory growth.
type exitCodeCapture struct {
	marker   string // e.g., "NEXUS_EXIT_a1b2c3d4="
	lastLine string // last matched line (replaces, not appends)
	partial  string // leftover from last Write that didn't end with \n
}

// newExitCodeCapture creates a capture that looks for the given marker prefix.
// marker should be like "NEXUS_EXIT_a1b2c3d4=".
func newExitCodeCapture(marker string) *exitCodeCapture {
	return &exitCodeCapture{marker: marker}
}

func (c *exitCodeCapture) Write(p []byte) (int, error) {
	data := c.partial + string(p)
	c.partial = ""

	for {
		idx := strings.IndexByte(data, '\n')
		if idx < 0 {
			// No more complete lines; save leftover.
			// Bound partial buffer to prevent memory exhaustion from a single long line.
			if len(data) > 4096 {
				data = data[len(data)-4096:]
			}
			c.partial = data
			break
		}
		line := data[:idx]
		data = data[idx+1:]
		if strings.Contains(line, c.marker) {
			c.lastLine = line // keep only last match
		}
	}
	return len(p), nil
}

// Flush processes any remaining partial line (call after all writes are done).
func (c *exitCodeCapture) Flush() {
	if c.partial != "" && strings.Contains(c.partial, c.marker) {
		c.lastLine = c.partial
	}
	c.partial = ""
}

// ExitCode parses and returns the exit code from the captured marker line.
// Returns -1 if no marker was found or parsing failed.
func (c *exitCodeCapture) ExitCode() int {
	if c.lastLine == "" {
		return -1
	}
	idx := strings.Index(c.lastLine, c.marker)
	if idx < 0 {
		return -1
	}
	numStr := c.lastLine[idx+len(c.marker):]
	// Take only the numeric part (stop at first non-digit).
	end := 0
	for end < len(numStr) && numStr[end] >= '0' && numStr[end] <= '9' {
		end++
	}
	if end == 0 {
		return -1
	}
	code, err := strconv.Atoi(numStr[:end])
	if err != nil {
		return -1
	}
	return code
}

func resolveCwd(cwd string) (string, error) {
	if cwd == "" {
		return guestWorkspace, nil
	}
	// Clean path to prevent traversal (e.g., "../../etc" → reject).
	if filepath.IsAbs(cwd) {
		cleaned := filepath.Clean(cwd)
		if cleaned != guestWorkspace && !strings.HasPrefix(cleaned, guestWorkspace+"/") {
			return "", fmt.Errorf("cwd %q escapes workspace", cwd)
		}
		return cleaned, nil
	}
	joined := filepath.Join(guestWorkspace, cwd)
	cleaned := filepath.Clean(joined)
	if cleaned != guestWorkspace && !strings.HasPrefix(cleaned, guestWorkspace+"/") {
		return "", fmt.Errorf("cwd %q escapes workspace", cwd)
	}
	return cleaned, nil
}

func minimalExecEnv() []string {
	return []string{
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME=/",
		"LANG=C",
		"LC_ALL=C",
	}
}
