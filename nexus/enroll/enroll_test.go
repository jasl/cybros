package enroll

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/protocol"
)

// enrollServer returns an httptest.Server that handles the enroll endpoint.
// If withCSR is true it returns fake cert/CA PEM in the response.
func enrollServer(t *testing.T, withCSR bool) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/conduits/v1/territories/enroll" {
			t.Errorf("unexpected path: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}

		var req protocol.EnrollRequest
		json.NewDecoder(r.Body).Decode(&req)

		resp := protocol.EnrollResponse{TerritoryID: "t-enrolled"}
		if withCSR {
			resp.MTLSClientCertPEM = "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n"
			resp.CABundlePEM = "-----BEGIN CERTIFICATE-----\nfake-ca\n-----END CERTIFICATE-----\n"
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}))
}

func testConfig(serverURL string) config.Config {
	cfg := config.Default()
	cfg.ServerURL = serverURL
	return cfg
}

// --- Run ---

func TestRun_EmptyToken(t *testing.T) {
	t.Parallel()

	_, err := Run(context.Background(), config.Default(), Options{EnrollToken: ""})
	if err == nil {
		t.Fatal("expected error for empty enroll_token")
	}
}

func TestRun_SimpleEnroll(t *testing.T) {
	t.Parallel()

	srv := enrollServer(t, false)
	defer srv.Close()

	result, err := Run(context.Background(), testConfig(srv.URL), Options{
		EnrollToken: "tok-abc",
		Name:        "test-node",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.TerritoryID != "t-enrolled" {
		t.Fatalf("expected territory ID t-enrolled, got %s", result.TerritoryID)
	}
	if result.ClientCertFile != "" || result.ClientKeyFile != "" {
		t.Error("expected no cert files for non-CSR enroll")
	}
}

func TestRun_WithCSR(t *testing.T) {
	t.Parallel()

	srv := enrollServer(t, true)
	defer srv.Close()

	outDir := filepath.Join(t.TempDir(), "certs")
	result, err := Run(context.Background(), testConfig(srv.URL), Options{
		EnrollToken: "tok-csr",
		Name:        "csr-node",
		WithCSR:     true,
		OutDir:      outDir,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.TerritoryID != "t-enrolled" {
		t.Fatalf("expected territory ID t-enrolled, got %s", result.TerritoryID)
	}

	// Verify cert files were written.
	for _, path := range []string{result.ClientKeyFile, result.ClientCertFile, result.CABundleFile} {
		if path == "" {
			t.Error("expected non-empty cert file path")
			continue
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Errorf("cert file %s: %v", path, err)
			continue
		}
		if info.Size() == 0 {
			t.Errorf("cert file %s is empty", path)
		}
	}

	// Key file should have restricted permissions.
	info, err := os.Stat(result.ClientKeyFile)
	if err != nil {
		t.Fatalf("stat key file: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("expected key file perm 0600, got %04o", perm)
	}
}

func TestRun_WithCSR_MissingOutDir(t *testing.T) {
	t.Parallel()

	_, err := Run(context.Background(), config.Default(), Options{
		EnrollToken: "tok",
		WithCSR:     true,
		OutDir:      "",
	})
	if err == nil {
		t.Fatal("expected error for empty OutDir with WithCSR=true")
	}
}

func TestRun_WithCSR_ServerOmitsCert(t *testing.T) {
	t.Parallel()

	// Server returns no cert PEM even though client sent CSR.
	srv := enrollServer(t, false)
	defer srv.Close()

	outDir := filepath.Join(t.TempDir(), "certs")
	_, err := Run(context.Background(), testConfig(srv.URL), Options{
		EnrollToken: "tok",
		WithCSR:     true,
		OutDir:      outDir,
	})
	if err == nil {
		t.Fatal("expected error when server omits mtls_client_cert_pem")
	}
}

func TestRun_WithLabels(t *testing.T) {
	t.Parallel()

	var captured protocol.EnrollRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&captured)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(protocol.EnrollResponse{TerritoryID: "t-labels"})
	}))
	defer srv.Close()

	_, err := Run(context.Background(), testConfig(srv.URL), Options{
		EnrollToken: "tok",
		Labels:      map[string]string{"env": "prod", "region": "us-west"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if captured.Labels["env"] != "prod" {
		t.Errorf("expected label env=prod, got %v", captured.Labels["env"])
	}
	if captured.Labels["region"] != "us-west" {
		t.Errorf("expected label region=us-west, got %v", captured.Labels["region"])
	}
}

func TestRun_ServerError(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	_, err := Run(context.Background(), testConfig(srv.URL), Options{
		EnrollToken: "tok",
	})
	if err == nil {
		t.Fatal("expected error for 500 response")
	}
}

func TestRun_ContextCancel(t *testing.T) {
	t.Parallel()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Slow server — will be canceled.
		<-r.Context().Done()
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	_, err := Run(ctx, testConfig(srv.URL), Options{
		EnrollToken: "tok",
	})
	if err == nil {
		t.Fatal("expected error for canceled context")
	}
}

// --- generateCSR ---

func TestGenerateCSR_WithName(t *testing.T) {
	t.Parallel()

	key, csrPEM, err := generateCSR("my-node")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key == nil {
		t.Fatal("expected non-nil key")
	}
	if key.N.BitLen() != 3072 {
		t.Errorf("expected 3072-bit key, got %d", key.N.BitLen())
	}

	block, _ := pem.Decode(csrPEM)
	if block == nil || block.Type != "CERTIFICATE REQUEST" {
		t.Fatal("expected PEM CERTIFICATE REQUEST block")
	}

	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil {
		t.Fatalf("parse CSR: %v", err)
	}
	if csr.Subject.CommonName != "my-node" {
		t.Errorf("expected CN=my-node, got %s", csr.Subject.CommonName)
	}
	if len(csr.Subject.Organization) == 0 || csr.Subject.Organization[0] != "Cybros Nexus" {
		t.Errorf("expected Organization=Cybros Nexus, got %v", csr.Subject.Organization)
	}
}

func TestGenerateCSR_EmptyName(t *testing.T) {
	t.Parallel()

	_, csrPEM, err := generateCSR("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	block, _ := pem.Decode(csrPEM)
	if block == nil {
		t.Fatal("expected PEM block")
	}
	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil {
		t.Fatalf("parse CSR: %v", err)
	}
	// Empty name should produce auto-generated CN starting with "nexus-".
	if len(csr.Subject.CommonName) < 6 || csr.Subject.CommonName[:6] != "nexus-" {
		t.Errorf("expected CN starting with nexus-, got %s", csr.Subject.CommonName)
	}
}

// --- writeFileAtomic ---

func TestWriteFileAtomic_Success(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "test.txt")
	content := []byte("hello, atomic write")

	if err := writeFileAtomic(path, content, 0o644); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if string(got) != string(content) {
		t.Fatalf("expected %q, got %q", content, got)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o644 {
		t.Errorf("expected perm 0644, got %04o", perm)
	}
}

func TestWriteFileAtomic_RestrictedPerm(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "secret.key")

	if err := writeFileAtomic(path, []byte("private"), 0o600); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("expected perm 0600, got %04o", perm)
	}
}

func TestWriteFileAtomic_NonexistentDir(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "nonexistent", "file.txt")
	err := writeFileAtomic(path, []byte("data"), 0o644)
	if err == nil {
		t.Fatal("expected error for nonexistent parent directory")
	}
}

func TestWriteFileAtomic_Overwrite(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "overwrite.txt")

	// Write initial content.
	if err := writeFileAtomic(path, []byte("first"), 0o644); err != nil {
		t.Fatalf("first write: %v", err)
	}
	// Overwrite.
	if err := writeFileAtomic(path, []byte("second"), 0o644); err != nil {
		t.Fatalf("second write: %v", err)
	}

	got, _ := os.ReadFile(path)
	if string(got) != "second" {
		t.Fatalf("expected second, got %q", got)
	}
}
