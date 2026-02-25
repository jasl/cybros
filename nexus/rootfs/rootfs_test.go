package rootfs

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/ulikunitz/xz"
)

func buildTestTarXZ(t *testing.T, entries map[string][]byte) []byte {
	t.Helper()

	var buf bytes.Buffer
	xzw, err := xz.NewWriter(&buf)
	if err != nil {
		t.Fatal(err)
	}
	tw := tar.NewWriter(xzw)

	for name, content := range entries {
		h := &tar.Header{
			Name: name,
			Mode: 0o755,
			Size: int64(len(content)),
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(content); err != nil {
			t.Fatal(err)
		}
	}

	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := xzw.Close(); err != nil {
		t.Fatal(err)
	}

	return buf.Bytes()
}

func TestEnsureUbuntu2404_DownloadExtractAndReuse(t *testing.T) {
	archive := buildTestTarXZ(t, map[string][]byte{
		"bin/sh": []byte("#!/bin/sh\necho ok\n"),
	})

	sum := sha256.Sum256(archive)
	sumHex := hex.EncodeToString(sum[:])

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(archive)
	}))
	defer srv.Close()

	cacheDir := t.TempDir()
	src := Source{URL: srv.URL + "/root.tar.xz", SHA256: sumHex}

	rootfsDir, err := EnsureUbuntu2404(context.Background(), cacheDir, "amd64", src)
	if err != nil {
		t.Fatalf("EnsureUbuntu2404: %v", err)
	}

	if _, err := os.Stat(filepath.Join(rootfsDir, "bin", "sh")); err != nil {
		t.Fatalf("expected bin/sh: %v", err)
	}

	// Second call should reuse existing rootfs (marker matches).
	rootfsDir2, err := EnsureUbuntu2404(context.Background(), cacheDir, "amd64", src)
	if err != nil {
		t.Fatalf("EnsureUbuntu2404 reuse: %v", err)
	}
	if rootfsDir2 != rootfsDir {
		t.Fatalf("rootfsDir changed: %q vs %q", rootfsDir2, rootfsDir)
	}
}

func TestEnsureUbuntu2404_SHA256MismatchFailsClosed(t *testing.T) {
	archive := buildTestTarXZ(t, map[string][]byte{
		"bin/sh": []byte("#!/bin/sh\necho ok\n"),
	})

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(archive)
	}))
	defer srv.Close()

	cacheDir := t.TempDir()
	src := Source{URL: srv.URL + "/root.tar.xz", SHA256: "deadbeef"}

	_, err := EnsureUbuntu2404(context.Background(), cacheDir, "amd64", src)
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestEnsureUbuntu2404_PathTraversalRejected(t *testing.T) {
	archive := buildTestTarXZ(t, map[string][]byte{
		"../evil": []byte("nope\n"),
		"bin/sh":  []byte("#!/bin/sh\necho ok\n"),
	})

	sum := sha256.Sum256(archive)
	sumHex := hex.EncodeToString(sum[:])

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(archive)
	}))
	defer srv.Close()

	cacheDir := t.TempDir()
	src := Source{URL: srv.URL + "/root.tar.xz", SHA256: sumHex}

	_, err := EnsureUbuntu2404(context.Background(), cacheDir, "amd64", src)
	if err == nil {
		t.Fatal("expected error")
	}
}
