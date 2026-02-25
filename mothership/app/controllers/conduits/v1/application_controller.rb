module Conduits
  module V1
    class ApplicationController < ActionController::API
      before_action :authenticate_territory!

      private

      # Territory authentication modes:
      #   "mtls"   — production: only accept client cert fingerprint (recommended)
      #   "header" — dev/test only: accept X-Nexus-Territory-Id header (spoofable!)
      #   "either" — accept fingerprint first, fall back to header (transitional)
      # Default is "mtls" for safety. Set CONDUITS_TERRITORY_AUTH_MODE=header for dev.
      def authenticate_territory!
        mode = (ENV["CONDUITS_TERRITORY_AUTH_MODE"] || "mtls").to_s # header|mtls|either

        fp_header = (ENV["CONDUITS_MTLS_FINGERPRINT_HEADER"] || "X-Nexus-Client-Cert-Fingerprint").to_s
        fingerprint = normalize_fingerprint(request.headers[fp_header])

        territory = nil
        if mode != "header" && fingerprint.present?
          # NOTE: This assumes the fingerprint header is injected by a trusted mTLS-terminating proxy.
          territory = Conduits::Territory.find_by(client_cert_fingerprint: fingerprint)
        end

        if territory.nil? && mode != "mtls"
          territory_id = request.headers["X-Nexus-Territory-Id"].to_s
          territory = Conduits::Territory.find_by(id: territory_id) if territory_id.present?
        end

        unless territory
          detail =
            if mode == "mtls"
              "missing or unknown client certificate fingerprint"
            else
              "missing territory identity"
            end
          render json: { error: "unauthorized", detail: detail }, status: :unauthorized
          return
        end

        @current_territory = territory
      end

      def current_territory
        @current_territory
      end

      # Authenticate directive_token for per-directive endpoints
      def authenticate_directive!
        token = extract_bearer_token
        unless token
          render json: { error: "unauthorized", detail: "missing directive token" }, status: :unauthorized
          return
        end

        claims = Conduits::DirectiveToken.decode(token)

        unless claims[:territory_id].to_s == current_territory&.id.to_s
          render json: { error: "forbidden", detail: "directive token territory mismatch" }, status: :forbidden
          return
        end

        @current_directive = Conduits::Directive.find_by(id: claims[:directive_id])

        unless @current_directive
          render json: { error: "not_found", detail: "directive not found" }, status: :not_found
          return
        end

        # Verify territory binding
        unless @current_directive.territory_id == current_territory&.id
          render json: { error: "forbidden", detail: "territory mismatch" }, status: :forbidden
          return
        end

        @current_directive
      rescue Conduits::DirectiveToken::ExpiredToken
        render json: { error: "unauthorized", detail: "directive token expired" }, status: :unauthorized
      rescue Conduits::DirectiveToken::InvalidToken => e
        render json: { error: "unauthorized", detail: e.message }, status: :unauthorized
      end

      def current_directive
        @current_directive
      end

      def extract_bearer_token
        auth_header = request.headers["Authorization"]
        return nil unless auth_header&.start_with?("Bearer ")

        auth_header.delete_prefix("Bearer ")
      end

      def normalize_fingerprint(value)
        value.to_s.strip.downcase.delete(":")
      end

      # Convert ActionController::Parameters to a plain hash.
      # Free-form JSON fields (labels, capabilities, limits, etc.) come through
      # as Parameters objects which cannot be merged or stored directly.
      def params_to_h(value, default = {})
        return default if value.nil?
        return value.to_unsafe_h if value.respond_to?(:to_unsafe_h)

        value
      end
    end
  end
end
