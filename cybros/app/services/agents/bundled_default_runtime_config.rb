require "uri"

module Agents
  class BundledDefaultRuntimeConfig
    MissingBootstrapConfigError = Class.new(StandardError)
    InvalidBootstrapConfigError = Class.new(StandardError)

    ENVIRONMENT_VARIABLES = {
      endpoint_url: "CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL",
      bearer: "CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER",
      fingerprint: "CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT",
    }.freeze

    def self.resolve
      new.resolve
    end

    def resolve
      {
        endpoint_url: endpoint_url,
        bearer: bearer,
        fingerprint: fingerprint,
        protocol_version: Agents::BootstrapBundledDefaultService::PROTOCOL_VERSION,
      }
    end

    private

      def endpoint_url
        value = fetch_required(:endpoint_url)
        uri = URI.parse(value)
        return value if uri.is_a?(URI::HTTP) && uri.host.present?

        raise InvalidBootstrapConfigError, "#{ENVIRONMENT_VARIABLES.fetch(:endpoint_url)} must be an absolute http(s) URL"
      rescue URI::InvalidURIError => error
        raise InvalidBootstrapConfigError, "#{ENVIRONMENT_VARIABLES.fetch(:endpoint_url)} is invalid: #{error.message}"
      end

      def bearer
        fetch_required(:bearer)
      end

      def fingerprint
        fetch_required(:fingerprint)
      end

      def fetch_required(key)
        variable_name = ENVIRONMENT_VARIABLES.fetch(key)
        value = ENV.fetch(variable_name, "").to_s.strip
        return value if value.present?

        raise MissingBootstrapConfigError, "Missing bundled claw bootstrap env: #{variable_name}"
      end
  end
end
