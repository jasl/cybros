//go:build linux

// Package landlock provides filesystem access control via the Linux Landlock LSM.
//
// Landlock restricts the calling process's filesystem access to explicitly
// permitted paths. Once applied, the ruleset is irrevocable — the process
// (and its children) cannot escape the permitted paths.
//
// Usage:
//
//	rs := landlock.NewRuleset()
//	rs.AddWritable("/workspace")
//	rs.AddReadOnly("/usr", "/etc", "/lib", "/lib64")
//	if err := rs.Apply(); err != nil {
//	    // handle: kernel too old, /proc not mounted, etc.
//	}
//	// Process is now restricted
//
// Requirements:
//   - Linux kernel >= 5.13 (ABI v1)
//   - Kernel >= 5.19 for file-refer (ABI v2) — gracefully degraded
//   - /proc mounted (for path_beneath fd resolution)
//
// Defense-in-depth: This supplements container/bwrap isolation. It is NOT
// a replacement — it restricts the trusted profile where no container exists.
package landlock

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

// Landlock ABI constants (from <linux/landlock.h>)
const (
	// Syscall numbers (amd64 / arm64)
	sysLandlockCreateRuleset = 444
	sysLandlockAddRule       = 445
	sysLandlockRestrictSelf  = 446

	// Rule types
	rulePathBeneath = 1

	// Access flags — ABI v1 (kernel 5.13+)
	accessFsExecute    = 1 << 0
	accessFsWriteFile  = 1 << 1
	accessFsReadFile   = 1 << 2
	accessFsReadDir    = 1 << 3
	accessFsRemoveDir  = 1 << 4
	accessFsRemoveFile = 1 << 5
	accessFsMakeChar   = 1 << 6
	accessFsMakeDir    = 1 << 7
	accessFsMakeReg    = 1 << 8
	accessFsMakeSock   = 1 << 9
	accessFsMakeFifo   = 1 << 10
	accessFsMakeBlock  = 1 << 11
	accessFsMakeSym    = 1 << 12

	// Composite masks
	accessRead  = accessFsExecute | accessFsReadFile | accessFsReadDir
	accessWrite = accessFsWriteFile | accessFsRemoveDir | accessFsRemoveFile |
		accessFsMakeChar | accessFsMakeDir | accessFsMakeReg |
		accessFsMakeSock | accessFsMakeFifo | accessFsMakeBlock | accessFsMakeSym

	accessAll = accessRead | accessWrite

	// prctl constants — defined locally for Go < 1.25 compatibility
	// (syscall.PR_SET_NO_NEW_PRIVS was added in Go 1.25)
	prSetNoNewPrivs = 38 // stable Linux ABI, see prctl(2)
)

// landlock_ruleset_attr for create_ruleset syscall
type rulesetAttr struct {
	handledAccessFs uint64
}

// landlock_path_beneath_attr for add_rule syscall
type pathBeneathAttr struct {
	allowedAccess uint64
	parentFd      int32
	_padding      int32 // ensure struct alignment matches kernel
}

// Ruleset accumulates filesystem access rules before applying them atomically.
type Ruleset struct {
	writablePaths  []string
	readOnlyPaths  []string
	applied        bool
}

// NewRuleset creates an empty ruleset.
func NewRuleset() *Ruleset {
	return &Ruleset{}
}

// AddWritable adds paths with full read+write access.
func (rs *Ruleset) AddWritable(paths ...string) {
	for _, p := range paths {
		abs, err := filepath.Abs(p)
		if err == nil {
			rs.writablePaths = append(rs.writablePaths, abs)
		}
	}
}

// AddReadOnly adds paths with read-only access.
func (rs *Ruleset) AddReadOnly(paths ...string) {
	for _, p := range paths {
		abs, err := filepath.Abs(p)
		if err == nil {
			rs.readOnlyPaths = append(rs.readOnlyPaths, abs)
		}
	}
}

// Available returns true if the running kernel supports Landlock.
// This does NOT modify the process state.
func Available() bool {
	attr := rulesetAttr{handledAccessFs: accessAll}
	fd, _, errno := syscall.RawSyscall(
		sysLandlockCreateRuleset,
		uintptr(unsafe.Pointer(&attr)),
		unsafe.Sizeof(attr),
		0,
	)
	if errno != 0 {
		return false
	}
	// Success: close the test fd
	syscall.Close(int(fd))
	return true
}

// Apply creates a Landlock ruleset, adds all configured paths, and restricts
// the calling process. Once applied, the restriction is permanent.
//
// Returns nil if no paths are configured (noop).
// Returns an error if the kernel doesn't support Landlock or a path doesn't exist.
func (rs *Ruleset) Apply() error {
	if rs.applied {
		return fmt.Errorf("landlock: ruleset already applied")
	}
	if len(rs.writablePaths) == 0 && len(rs.readOnlyPaths) == 0 {
		return nil // noop — no restrictions configured
	}

	// Step 1: Create ruleset
	attr := rulesetAttr{handledAccessFs: accessAll}
	fd, _, errno := syscall.RawSyscall(
		sysLandlockCreateRuleset,
		uintptr(unsafe.Pointer(&attr)),
		unsafe.Sizeof(attr),
		0,
	)
	if errno != 0 {
		return fmt.Errorf("landlock: create_ruleset: %w (is kernel >= 5.13?)", errno)
	}
	rulesetFd := int(fd)
	defer syscall.Close(rulesetFd)

	// Step 2: Add writable paths (read + write)
	for _, path := range rs.writablePaths {
		if err := addPathRule(rulesetFd, path, accessAll); err != nil {
			return fmt.Errorf("landlock: add writable %q: %w", path, err)
		}
	}

	// Step 3: Add read-only paths
	for _, path := range rs.readOnlyPaths {
		if err := addPathRule(rulesetFd, path, accessRead); err != nil {
			return fmt.Errorf("landlock: add read-only %q: %w", path, err)
		}
	}

	// Step 4: Restrict self (no_new_privs required first)
	if err := prctl(prSetNoNewPrivs, 1); err != nil {
		return fmt.Errorf("landlock: prctl(NO_NEW_PRIVS): %w", err)
	}

	_, _, errno = syscall.RawSyscall(
		sysLandlockRestrictSelf,
		uintptr(rulesetFd),
		0,
		0,
	)
	if errno != 0 {
		return fmt.Errorf("landlock: restrict_self: %w", errno)
	}

	rs.applied = true
	return nil
}

// addPathRule opens a path and adds a Landlock path-beneath rule to the ruleset.
func addPathRule(rulesetFd int, path string, access uint64) error {
	// Open the path to get an fd for the kernel
	fd, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open %q: %w", path, err)
	}
	defer fd.Close()

	pathFd := int(fd.Fd())
	rule := pathBeneathAttr{
		allowedAccess: access,
		parentFd:      int32(pathFd),
	}

	_, _, errno := syscall.RawSyscall6(
		sysLandlockAddRule,
		uintptr(rulesetFd),
		rulePathBeneath,
		uintptr(unsafe.Pointer(&rule)),
		0,
		0,
		0,
	)
	if errno != 0 {
		return fmt.Errorf("add_rule for %q: %w", path, errno)
	}
	return nil
}

func prctl(option int, arg uintptr) error {
	_, _, errno := syscall.RawSyscall6(
		syscall.SYS_PRCTL,
		uintptr(option),
		arg,
		0, 0, 0, 0,
	)
	if errno != 0 {
		return errno
	}
	return nil
}
