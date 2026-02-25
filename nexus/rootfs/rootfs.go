package rootfs

import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/ulikunitz/xz"
)

const maxRootfsDownloadSize = 2 * 1024 * 1024 * 1024 // 2 GiB

type Source struct {
	URL    string
	SHA256 string
}

const (
	ubuntu2404Dirname = "ubuntu-24.04"
	markerFilename    = ".nexus_rootfs_sha256"
)

func EnsureUbuntu2404(ctx context.Context, cacheDir string, arch string, src Source) (string, error) {
	if cacheDir == "" {
		return "", errors.New("rootfs cache_dir is required")
	}
	if src.URL == "" || src.SHA256 == "" {
		return "", errors.New("rootfs source url and sha256 are required")
	}
	if arch != "amd64" && arch != "arm64" {
		return "", fmt.Errorf("unsupported arch: %q", arch)
	}

	rootfsDir := filepath.Join(cacheDir, ubuntu2404Dirname, arch, "rootfs")

	lockPath := filepath.Join(cacheDir, "locks", ubuntu2404Dirname+"-"+arch+".lock")
	if err := withFileLock(lockPath, func() error {
		if ok, err := rootfsValid(rootfsDir, strings.ToLower(src.SHA256)); err != nil {
			return err
		} else if ok {
			return nil
		}

		downloadDir := filepath.Join(cacheDir, "downloads")
		downloadPath, err := ensureDownloaded(ctx, downloadDir, src)
		if err != nil {
			return err
		}

		parent := filepath.Dir(rootfsDir)
		if err := os.MkdirAll(parent, 0o755); err != nil {
			return fmt.Errorf("create rootfs dir parent: %w", err)
		}

		tmpDir, err := os.MkdirTemp(parent, "rootfs-tmp-*")
		if err != nil {
			return fmt.Errorf("create temp rootfs dir: %w", err)
		}
		defer os.RemoveAll(tmpDir)

		if err := extractTarXZ(downloadPath, tmpDir); err != nil {
			return err
		}

		if err := os.WriteFile(filepath.Join(tmpDir, markerFilename), []byte(strings.ToLower(src.SHA256)+"\n"), 0o644); err != nil {
			return fmt.Errorf("write marker: %w", err)
		}
		if err := ensureBinSh(tmpDir); err != nil {
			return err
		}

		_ = os.RemoveAll(rootfsDir)
		if err := os.Rename(tmpDir, rootfsDir); err != nil {
			return fmt.Errorf("rename rootfs dir: %w", err)
		}

		return nil
	}); err != nil {
		return "", err
	}

	return rootfsDir, nil
}

func rootfsValid(rootfsDir string, expectedSHA string) (bool, error) {
	markerPath := filepath.Join(rootfsDir, markerFilename)
	b, err := os.ReadFile(markerPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, fmt.Errorf("read rootfs marker: %w", err)
	}
	if strings.TrimSpace(string(b)) != strings.TrimSpace(expectedSHA) {
		return false, nil
	}

	if err := ensureBinSh(rootfsDir); err != nil {
		return false, nil
	}
	return true, nil
}

func ensureBinSh(rootfsDir string) error {
	shPath := filepath.Join(rootfsDir, "bin", "sh")
	if _, err := os.Stat(shPath); err != nil {
		return fmt.Errorf("rootfs missing %s: %w", shPath, err)
	}
	return nil
}

func ensureDownloaded(ctx context.Context, downloadDir string, src Source) (string, error) {
	if err := os.MkdirAll(downloadDir, 0o755); err != nil {
		return "", fmt.Errorf("create download dir: %w", err)
	}

	u, err := url.Parse(src.URL)
	if err != nil {
		return "", fmt.Errorf("parse rootfs url: %w", err)
	}
	filename := path.Base(u.Path)
	if filename == "" || filename == "." || filename == "/" {
		return "", fmt.Errorf("invalid rootfs url path: %q", u.Path)
	}

	dst := filepath.Join(downloadDir, filename)
	if ok, err := fileSHA256Matches(dst, src.SHA256); err != nil {
		return "", err
	} else if ok {
		return dst, nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src.URL, nil)
	if err != nil {
		return "", err
	}
	httpClient := &http.Client{
		Timeout: 30 * time.Minute,
		CheckRedirect: func(_ *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			return nil
		},
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("download rootfs: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("download rootfs: HTTP %d", resp.StatusCode)
	}

	tmpFile, err := os.CreateTemp(downloadDir, filename+".tmp-*")
	if err != nil {
		return "", fmt.Errorf("create temp download: %w", err)
	}
	tmpName := tmpFile.Name()
	defer os.Remove(tmpName)

	hasher := sha256.New()
	w := io.MultiWriter(tmpFile, hasher)

	if _, err := io.Copy(w, io.LimitReader(resp.Body, maxRootfsDownloadSize)); err != nil {
		tmpFile.Close()
		return "", fmt.Errorf("write download: %w", err)
	}
	if err := tmpFile.Close(); err != nil {
		return "", fmt.Errorf("close download: %w", err)
	}

	sumHex := hex.EncodeToString(hasher.Sum(nil))
	if strings.ToLower(strings.TrimSpace(sumHex)) != strings.ToLower(strings.TrimSpace(src.SHA256)) {
		return "", fmt.Errorf("rootfs sha256 mismatch: got=%s want=%s", sumHex, src.SHA256)
	}

	if err := os.Rename(tmpName, dst); err != nil {
		return "", fmt.Errorf("finalize download: %w", err)
	}

	return dst, nil
}

func fileSHA256Matches(path string, expected string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	defer f.Close()

	hasher := sha256.New()
	if _, err := io.Copy(hasher, f); err != nil {
		return false, err
	}
	sumHex := hex.EncodeToString(hasher.Sum(nil))
	return strings.ToLower(strings.TrimSpace(sumHex)) == strings.ToLower(strings.TrimSpace(expected)), nil
}

func extractTarXZ(archivePath string, destDir string) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return fmt.Errorf("open rootfs archive: %w", err)
	}
	defer f.Close()

	xzr, err := xz.NewReader(f)
	if err != nil {
		return fmt.Errorf("xz reader: %w", err)
	}

	tr := tar.NewReader(xzr)
	for {
		hdr, err := tr.Next()
		if err != nil {
			if err == io.EOF {
				break
			}
			return fmt.Errorf("tar read: %w", err)
		}

		switch hdr.Typeflag {
		case tar.TypeXGlobalHeader, tar.TypeXHeader:
			continue
		}

		target, err := safeTarPath(destDir, hdr.Name)
		if err != nil {
			return err
		}

		mode := hdr.FileInfo().Mode()

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return fmt.Errorf("mkdir %s: %w", target, err)
			}
			_ = os.Chmod(target, mode.Perm())

		case tar.TypeReg, tar.TypeRegA:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return fmt.Errorf("mkdir parent: %w", err)
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode.Perm())
			if err != nil {
				return fmt.Errorf("create file %s: %w", target, err)
			}
			if _, err := io.CopyN(out, tr, hdr.Size); err != nil {
				out.Close()
				return fmt.Errorf("write file %s: %w", target, err)
			}
			if err := out.Close(); err != nil {
				return fmt.Errorf("close file %s: %w", target, err)
			}

		case tar.TypeSymlink:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return fmt.Errorf("mkdir parent: %w", err)
			}
			// Validate symlink target stays within destDir to prevent zip-slip via symlinks.
			// Ubuntu rootfs tarballs may use absolute symlinks (e.g., /bin -> usr/bin);
			// treat absolute targets as relative to destDir (the tar root).
			if err := validateSymlinkTarget(destDir, target, hdr.Linkname); err != nil {
				return err
			}
			if err := os.Symlink(hdr.Linkname, target); err != nil {
				return fmt.Errorf("symlink %s -> %s: %w", target, hdr.Linkname, err)
			}

		case tar.TypeLink:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return fmt.Errorf("mkdir parent: %w", err)
			}
			linkTarget, err := safeTarPath(destDir, hdr.Linkname)
			if err != nil {
				return err
			}
			if err := os.Link(linkTarget, target); err != nil {
				return fmt.Errorf("hardlink %s -> %s: %w", target, hdr.Linkname, err)
			}

		default:
			return fmt.Errorf("unsupported tar entry type %d for %q", hdr.Typeflag, hdr.Name)
		}
	}

	return nil
}

func safeTarPath(destRoot string, name string) (string, error) {
	if name == "" {
		return "", errors.New("tar entry has empty path")
	}

	clean := path.Clean(name)
	clean = strings.TrimPrefix(clean, "./")
	if clean == "." || clean == "" {
		return "", errors.New("tar entry has empty path after cleaning")
	}
	if path.IsAbs(clean) {
		return "", fmt.Errorf("tar entry uses absolute path: %q", name)
	}
	if clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("tar entry path traversal: %q", name)
	}

	target := filepath.Join(destRoot, filepath.FromSlash(clean))
	rel, err := filepath.Rel(destRoot, target)
	if err != nil {
		return "", err
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("tar entry escapes destination: %q", name)
	}
	return target, nil
}

// validateSymlinkTarget ensures that a symlink's resolved target stays within destDir.
// Absolute link targets are treated as relative to destDir (the tarball root), which is
// standard for rootfs tarballs (e.g., /bin -> usr/bin means <destDir>/usr/bin).
func validateSymlinkTarget(destDir string, symlinkPath string, linkTarget string) error {
	var resolved string
	if filepath.IsAbs(linkTarget) {
		// Absolute: treat destDir as the filesystem root.
		resolved = filepath.Join(destDir, filepath.Clean(linkTarget))
	} else {
		// Relative: resolve against the symlink's parent directory.
		resolved = filepath.Join(filepath.Dir(symlinkPath), linkTarget)
	}
	resolved = filepath.Clean(resolved)

	rel, err := filepath.Rel(destDir, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("tar symlink %q -> %q escapes destination", filepath.Base(symlinkPath), linkTarget)
	}
	return nil
}

func withFileLock(lockPath string, fn func() error) error {
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o755); err != nil {
		return fmt.Errorf("create lock dir: %w", err)
	}

	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open lock file: %w", err)
	}
	defer f.Close()

	deadline := time.Now().Add(10 * time.Minute)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			return fmt.Errorf("flock: %w", err)
		}
		if time.Now().After(deadline) {
			return errors.New("timed out waiting for rootfs lock")
		}
		time.Sleep(100 * time.Millisecond)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)

	return fn()
}
