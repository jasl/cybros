require "test_helper"
require "openssl"

class Conduits::Mtls::CertificateAuthorityTest < ActiveSupport::TestCase
  test "issue_client_cert! returns valid cert with SHA-256 fingerprint" do
    key = OpenSSL::PKey::RSA.new(2048)
    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.parse("/CN=test-nexus/O=Test")
    csr.public_key = key.public_key
    csr.sign(key, OpenSSL::Digest::SHA256.new)

    issued = Conduits::Mtls::CertificateAuthority.issue_client_cert!(csr.to_pem)

    assert issued.client_cert_pem.present?
    assert issued.ca_bundle_pem.present?
    assert issued.fingerprint.present?

    # Verify fingerprint is SHA-256 (64 hex chars)
    assert_equal 64, issued.fingerprint.length
    assert_match(/\A[0-9a-f]{64}\z/, issued.fingerprint)

    # Verify fingerprint matches SHA-256 of the cert DER
    cert = OpenSSL::X509::Certificate.new(issued.client_cert_pem)
    expected = OpenSSL::Digest::SHA256.hexdigest(cert.to_der)
    assert_equal expected, issued.fingerprint
  end

  test "issue_client_cert! rejects invalid CSR" do
    assert_raises(OpenSSL::X509::RequestError) do
      Conduits::Mtls::CertificateAuthority.issue_client_cert!("not-a-pem")
    end
  end

  test "newly generated CA key is 3072-bit RSA" do
    ca_dir = Conduits::Mtls::CertificateAuthority::CA_DIR
    key_path = ca_dir.join("ca.key")
    cert_path = ca_dir.join("ca.crt")

    # Back up existing files if present
    key_backup = key_path.exist? ? key_path.read : nil
    cert_backup = cert_path.exist? ? cert_path.read : nil

    begin
      # Remove existing CA so load_or_create_ca! generates fresh keys
      key_path.delete if key_path.exist?
      cert_path.delete if cert_path.exist?

      ca_key, _ca_cert = Conduits::Mtls::CertificateAuthority.load_or_create_ca!
      assert_equal 3072, ca_key.n.num_bits
    ensure
      # Restore original files
      if key_backup
        key_path.write(key_backup)
        File.chmod(0o600, key_path)
      end
      if cert_backup
        cert_path.write(cert_backup)
        File.chmod(0o644, cert_path)
      end
    end
  end
end
