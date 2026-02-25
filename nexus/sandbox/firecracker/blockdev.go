package firecracker

import (
	"fmt"
	"os/exec"
	"strconv"
)

// CreateImageFromDir creates an ext4 image from a directory using mke2fs -d.
// No root required. The image file is created at imagePath with the given size.
func CreateImageFromDir(dir, imagePath string, sizeMiB int) error {
	if dir == "" {
		return fmt.Errorf("source directory is required")
	}
	if imagePath == "" {
		return fmt.Errorf("image path is required")
	}
	if sizeMiB <= 0 {
		return fmt.Errorf("size must be > 0 MiB")
	}

	sizeStr := strconv.Itoa(sizeMiB) + "M"

	// mke2fs -t ext4 -d <dir> <image> <size>
	// -F: force (create even if not a device)
	// -d: populate from directory
	cmd := exec.Command("mke2fs",
		"-t", "ext4",
		"-F",
		"-d", dir,
		imagePath,
		sizeStr,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("mke2fs: %w: %s", err, out)
	}
	return nil
}

// ExtractImageToDir extracts files from an ext4 image to a directory
// using fuse2fs (FUSE mount, no root required).
// It mounts the image read-only and copies files to the destination.
func ExtractImageToDir(imagePath, dir string) error {
	if imagePath == "" {
		return fmt.Errorf("image path is required")
	}
	if dir == "" {
		return fmt.Errorf("destination directory is required")
	}

	// Use fuse2fs to mount the image, then cp the contents.
	// fuse2fs <image> <mountpoint> -o ro,fakeroot
	//
	// We use a helper approach: mount → cp → fusermount -u
	// The script captures the cp exit code separately because cleanup
	// (fusermount/rmdir) might fail even after a successful copy.
	//
	// Security hardening:
	//   - Use cp -rp (not -a) to avoid preserving symlinks as-is.
	//     A malicious guest could craft symlinks pointing outside the workspace.
	//   - Strip setuid/setgid bits from extracted files to prevent
	//     privilege escalation across directive executions.
	//   - Remove any symlinks that point outside the destination directory.
	script := fmt.Sprintf(`
MOUNT_DIR=$(mktemp -d)
DST=%s
trap 'fusermount -u "$MOUNT_DIR" 2>/dev/null; rmdir "$MOUNT_DIR" 2>/dev/null' EXIT

fuse2fs %s "$MOUNT_DIR" -o ro,fakeroot || exit 1

# Copy without following symlinks (-rp instead of -a).
# -r: recursive; -p: preserve timestamps/permissions (but not symlinks-as-links).
cp -rp --no-preserve=links "$MOUNT_DIR"/. "$DST"/
CP_EXIT=$?

# Strip setuid/setgid bits from extracted files (defense-in-depth).
find "$DST" -perm /6000 -exec chmod ug-s {} + 2>/dev/null || true

# Remove symlinks pointing outside the destination directory.
find "$DST" -type l | while IFS= read -r link; do
  target=$(readlink -f "$link" 2>/dev/null) || true
  case "$target" in
    "$DST"/*) ;;
    *) rm -f "$link" ;;
  esac
done

fusermount -u "$MOUNT_DIR" 2>/dev/null || true
rmdir "$MOUNT_DIR" 2>/dev/null || true
exit $CP_EXIT
`, shellQuote(dir), shellQuote(imagePath))

	cmd := exec.Command("/bin/sh", "-c", script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("fuse2fs extract: %w: %s", err, out)
	}
	return nil
}

