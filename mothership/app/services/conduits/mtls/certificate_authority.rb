require "openssl"

module Conduits
  module Mtls
    class CertificateAuthority
      CA_DIR = Rails.root.join("storage", "conduits", "mtls")
      CA_KEY_PATH = CA_DIR.join("ca.key")
      CA_CERT_PATH = CA_DIR.join("ca.crt")

      IssuedCert = Data.define(:client_cert_pem, :ca_bundle_pem, :fingerprint)

      def self.issue_client_cert!(csr_pem, validity: 30.days)
        ca_key, ca_cert = load_or_create_ca!

        csr = OpenSSL::X509::Request.new(csr_pem)
        raise ArgumentError, "invalid CSR signature" unless csr.verify(csr.public_key)

        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = SecureRandom.random_number(2**63)
        cert.subject = csr.subject
        cert.issuer = ca_cert.subject
        cert.public_key = csr.public_key
        cert.not_before = Time.current - 60
        cert.not_after = Time.current + validity

        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = cert
        ef.issuer_certificate = ca_cert

        cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE", true))
        cert.add_extension(ef.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
        cert.add_extension(ef.create_extension("extendedKeyUsage", "clientAuth", false))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
        cert.add_extension(ef.create_extension("authorityKeyIdentifier", "keyid:always,issuer:always", false))

        cert.sign(ca_key, OpenSSL::Digest::SHA256.new)

        IssuedCert.new(
          client_cert_pem: cert.to_pem,
          ca_bundle_pem: ca_cert.to_pem,
          fingerprint: fingerprint(cert)
        )
      end

      def self.load_or_create_ca!
        CA_DIR.mkpath

        if CA_KEY_PATH.exist? && CA_CERT_PATH.exist?
          return [
            OpenSSL::PKey.read(CA_KEY_PATH.read),
            OpenSSL::X509::Certificate.new(CA_CERT_PATH.read),
          ]
        end

        key = OpenSSL::PKey::RSA.new(3072)

        name = OpenSSL::X509::Name.parse("/O=Cybros Nexus/CN=Cybros Conduits CA")
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = SecureRandom.random_number(2**63)
        cert.subject = name
        cert.issuer = name
        cert.public_key = key.public_key
        cert.not_before = Time.current - 60
        cert.not_after = Time.current + 10.years

        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = cert
        ef.issuer_certificate = cert

        cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(ef.create_extension("keyUsage", "keyCertSign,cRLSign", true))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
        cert.add_extension(ef.create_extension("authorityKeyIdentifier", "keyid:always,issuer:always", false))

        cert.sign(key, OpenSSL::Digest::SHA256.new)

        CA_KEY_PATH.write(key.to_pem)
        File.chmod(0o600, CA_KEY_PATH)
        CA_CERT_PATH.write(cert.to_pem)
        File.chmod(0o644, CA_CERT_PATH)

        [key, cert]
      end

      def self.fingerprint(cert)
        OpenSSL::Digest::SHA256.hexdigest(cert.to_der)
      end
    end
  end
end
