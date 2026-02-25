package enroll

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"cybros.ai/nexus/client"
	"cybros.ai/nexus/config"
	"cybros.ai/nexus/protocol"
)

type Options struct {
	EnrollToken string
	Name        string
	Labels      map[string]string

	OutDir  string
	WithCSR bool
}

type Result struct {
	TerritoryID    string `json:"territory_id"`
	ClientCertFile string `json:"client_cert_file,omitempty"`
	ClientKeyFile  string `json:"client_key_file,omitempty"`
	CABundleFile   string `json:"ca_bundle_file,omitempty"`
}

func Run(ctx context.Context, cfg config.Config, opts Options) (Result, error) {
	if opts.EnrollToken == "" {
		return Result{}, fmt.Errorf("enroll_token is required")
	}

	cli, err := client.New(cfg)
	if err != nil {
		return Result{}, err
	}

	req := protocol.EnrollRequest{
		EnrollToken: opts.EnrollToken,
		Name:        opts.Name,
	}
	if len(opts.Labels) > 0 {
		req.Labels = map[string]any{}
		for k, v := range opts.Labels {
			req.Labels[k] = v
		}
	}

	var keyPEM []byte
	if opts.WithCSR {
		if opts.OutDir == "" {
			return Result{}, fmt.Errorf("out_dir is required when with_csr=true")
		}

		key, csrPEM, err := generateCSR(opts.Name)
		if err != nil {
			return Result{}, err
		}
		req.CSRPEM = string(csrPEM)

		keyPEM = pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	}

	reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := cli.Enroll(reqCtx, req)
	if err != nil {
		return Result{}, err
	}

	result := Result{TerritoryID: resp.TerritoryID}

	if opts.WithCSR {
		if resp.MTLSClientCertPEM == "" || resp.CABundlePEM == "" {
			return Result{}, fmt.Errorf("server did not return mtls_client_cert_pem/ca_bundle_pem")
		}

		if err := os.MkdirAll(opts.OutDir, 0o700); err != nil {
			return Result{}, err
		}

		keyPath := filepath.Join(opts.OutDir, "client.key")
		certPath := filepath.Join(opts.OutDir, "client.crt")
		caPath := filepath.Join(opts.OutDir, "ca_bundle.crt")

		if err := writeFileAtomic(keyPath, keyPEM, 0o600); err != nil {
			return Result{}, err
		}
		if err := writeFileAtomic(certPath, []byte(resp.MTLSClientCertPEM), 0o644); err != nil {
			return Result{}, err
		}
		if err := writeFileAtomic(caPath, []byte(resp.CABundlePEM), 0o644); err != nil {
			return Result{}, err
		}

		result.ClientKeyFile = keyPath
		result.ClientCertFile = certPath
		result.CABundleFile = caPath
	}

	return result, nil
}

func generateCSR(name string) (*rsa.PrivateKey, []byte, error) {
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		return nil, nil, err
	}

	cn := name
	if cn == "" {
		cn = fmt.Sprintf("nexus-%d", time.Now().Unix())
	}

	template := &x509.CertificateRequest{
		Subject: pkix.Name{
			Organization: []string{"Cybros Nexus"},
			CommonName:   cn,
		},
		SignatureAlgorithm: x509.SHA256WithRSA,
	}

	csrDER, err := x509.CreateCertificateRequest(rand.Reader, template, key)
	if err != nil {
		return nil, nil, err
	}

	csrPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: csrDER})
	return key, csrPEM, nil
}

func writeFileAtomic(path string, b []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, ".nexus-tmp-*")
	if err != nil {
		return err
	}
	tmp := f.Name()

	if _, err := f.Write(b); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Chmod(perm); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
