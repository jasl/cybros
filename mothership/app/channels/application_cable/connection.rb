module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_territory

    def connect
      self.current_territory = find_verified_territory
    end

    private

    def find_verified_territory
      # Support two auth modes for WebSocket:
      # 1. mTLS fingerprint (production) — passed as query param since WS upgrades
      #    don't support custom headers in all clients
      # 2. Territory ID header/param (dev/test)
      mode = (ENV["CONDUITS_TERRITORY_AUTH_MODE"] || "mtls").to_s

      territory = nil

      if mode != "header"
        fingerprint = normalize_fingerprint(request.params[:fingerprint])
        territory = Conduits::Territory.find_by(client_cert_fingerprint: fingerprint) if fingerprint.present?
      end

      if territory.nil? && mode != "mtls"
        territory_id = request.params[:territory_id].to_s
        territory = Conduits::Territory.find_by(id: territory_id) if territory_id.present?
      end

      territory || reject_unauthorized_connection
    end

    def normalize_fingerprint(value)
      value.to_s.strip.downcase.delete(":")
    end
  end
end
