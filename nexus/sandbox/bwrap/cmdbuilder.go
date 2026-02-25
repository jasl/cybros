// Package bwrap implements a bubblewrap-based sandbox driver for Linux.
// The cmdbuilder and wrapper files have no build tag so they can be
// unit-tested on any platform; only bwrap.go is Linux-only.
package bwrap

import (
	"fmt"
	"path"
	"strings"
)

// CmdConfig holds the inputs needed to construct a bwrap invocation.
type CmdConfig struct {
	// BwrapPath is the path to the bubblewrap binary.
	BwrapPath string

	// RootfsPath is the read-only root filesystem to bind.
	// Empty string means use host directories with a tmpfs root
	// (the default mode for Ubuntu 24.04 merged-usr layout).
	RootfsPath string

	// FacilityPath is the host-side path to the facility directory.
	// It will be bind-mounted read-write at /workspace.
	FacilityPath string

	// ProxySocketPath is the host-side path to the egress proxy UDS.
	// Bind-mounted read-only at /run/egress-proxy.sock.
	ProxySocketPath string

	// WrapperScriptPath is the host-side path to the wrapper script.
	// Bind-mounted read-only at /run/wrapper.sh.
	WrapperScriptPath string

	// Cwd is the working directory inside the sandbox. Default: /workspace.
	Cwd string

	// HostHasLib64 indicates whether the host has /lib64 (x86_64 systems).
	// When true, a /lib64 -> usr/lib64 symlink is created in the sandbox.
	HostHasLib64 bool
}

const (
	sandboxWorkspace = "/workspace"
	sandboxProxySock = "/run/egress-proxy.sock"
	sandboxWrapperSh = "/run/wrapper.sh"
	sandboxProxyPort = 9080
)

// SandboxWorkspace returns the sandbox-internal workspace path.
func SandboxWorkspace() string { return sandboxWorkspace }

// SandboxProxySock returns the sandbox-internal proxy socket path.
func SandboxProxySock() string { return sandboxProxySock }

// SandboxProxyPort returns the socat bridge TCP port inside the sandbox.
func SandboxProxyPort() int { return sandboxProxyPort }

// BuildArgs constructs the bwrap argument slice (including the bwrap binary).
func BuildArgs(cfg CmdConfig) ([]string, error) {
	if cfg.BwrapPath == "" {
		return nil, fmt.Errorf("bwrap path is required")
	}
	if cfg.FacilityPath == "" {
		return nil, fmt.Errorf("facility path is required")
	}
	if cfg.ProxySocketPath == "" {
		return nil, fmt.Errorf("proxy socket path is required")
	}
	if cfg.WrapperScriptPath == "" {
		return nil, fmt.Errorf("wrapper script path is required")
	}

	// NOTE: Phase 1 facility prepare runs inside the sandbox driver.
	// bwrap must start at /workspace so prepare (git clone) can succeed,
	// then the wrapper script will cd to the requested cwd (after prepare).
	_, err := resolveCwd(cfg.Cwd)
	if err != nil {
		return nil, err
	}

	args := []string{cfg.BwrapPath}

	if cfg.RootfsPath != "" {
		// Custom rootfs: bind it read-only as the entire root.
		args = append(args, "--ro-bind", cfg.RootfsPath, "/")
	} else {
		// Default mode: tmpfs root with host directories selectively mounted.
		// This avoids requiring /workspace to exist on the host filesystem,
		// and exposes only the minimal set of host paths needed.
		args = appendHostRootArgs(args, cfg.HostHasLib64)
	}

	// Virtual filesystems
	args = append(args, "--proc", "/proc")
	args = append(args, "--dev", "/dev")
	args = append(args, "--tmpfs", "/tmp")

	// Writable /run for proxy socket and wrapper script
	args = append(args, "--tmpfs", "/run")

	// Writable workspace
	args = append(args, "--bind", cfg.FacilityPath, sandboxWorkspace)

	// Proxy socket (read-only inside sandbox)
	args = append(args, "--ro-bind", cfg.ProxySocketPath, sandboxProxySock)

	// Wrapper script (read-only inside sandbox)
	args = append(args, "--ro-bind", cfg.WrapperScriptPath, sandboxWrapperSh)

	// Lock down the root filesystem after all mounts are set up.
	// This makes the tmpfs root read-only while preserving writable
	// submounts (/workspace, /tmp, /run).
	args = append(args, "--remount-ro", "/")

	// Namespace isolation
	args = append(args,
		"--unshare-net",
		"--unshare-pid",
		"--unshare-uts",
		"--unshare-ipc",
	)

	// Security hardening
	args = append(args,
		"--new-session",
		"--die-with-parent",
		"--cap-drop", "ALL",
	)

	// Working directory
	args = append(args, "--chdir", sandboxWorkspace)

	// Execute wrapper
	args = append(args, "--", "/bin/sh", sandboxWrapperSh)

	return args, nil
}

func resolveCwd(requested string) (string, error) {
	cwd := requested
	if cwd == "" || cwd == "." {
		cwd = sandboxWorkspace
	}
	if !strings.HasPrefix(cwd, "/") {
		cwd = sandboxWorkspace + "/" + cwd
	}
	// Clean and validate to prevent path traversal (e.g., "../../etc")
	cwd = path.Clean(cwd)
	if cwd != sandboxWorkspace && !strings.HasPrefix(cwd, sandboxWorkspace+"/") {
		return "", fmt.Errorf("cwd %q escapes workspace", requested)
	}
	return cwd, nil
}

// appendHostRootArgs builds the root filesystem from host directories using
// a tmpfs root with selective read-only bind mounts. This follows the
// Ubuntu 24.04 merged-usr layout where /bin, /sbin, /lib are symlinks
// to their /usr counterparts.
func appendHostRootArgs(args []string, hasLib64 bool) []string {
	// Writable tmpfs root — mount points can be created freely.
	args = append(args, "--tmpfs", "/")

	// Host /usr contains all binaries, libraries, and shared data.
	args = append(args, "--ro-bind", "/usr", "/usr")

	// Merged-usr symlinks (Ubuntu 24.04 layout).
	args = append(args, "--symlink", "usr/bin", "/bin")
	args = append(args, "--symlink", "usr/sbin", "/sbin")
	args = append(args, "--symlink", "usr/lib", "/lib")

	// x86_64 systems may have /lib64 -> /usr/lib64.
	if hasLib64 {
		args = append(args, "--symlink", "usr/lib64", "/lib64")
	}

	// Host /etc for system configuration (resolv.conf, passwd, etc.)
	args = append(args, "--ro-bind", "/etc", "/etc")

	return args
}
