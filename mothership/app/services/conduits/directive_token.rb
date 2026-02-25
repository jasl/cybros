module Conduits
  # Generates and validates short-lived JWTs scoped to a single directive.
  # Used by Nexus to authenticate when reporting started/heartbeat/log_chunks/finished.
  class DirectiveToken
    ALGORITHM = "HS256"
    # Keep tokens short-lived and refresh them via the heartbeat endpoint.
    # This limits blast radius if a token leaks while still supporting long-running directives.
    DEFAULT_TTL = 5.minutes

    class InvalidToken < StandardError; end
    class ExpiredToken < StandardError; end

    def self.encode(directive_id:, territory_id:, ttl: DEFAULT_TTL)
      payload = {
        sub: directive_id,
        tid: territory_id,
        iat: Time.current.to_i,
        exp: (Time.current + ttl).to_i,
      }
      JWT.encode(payload, secret_key, ALGORITHM)
    end

    def self.decode(token)
      payload = JWT.decode(token, secret_key, true, algorithm: ALGORITHM).first
      {
        directive_id: payload["sub"],
        territory_id: payload["tid"],
      }
    rescue JWT::ExpiredSignature
      raise ExpiredToken, "Directive token has expired"
    rescue JWT::DecodeError => e
      raise InvalidToken, "Invalid directive token: #{e.message}"
    end

    def self.secret_key
      Rails.application.secret_key_base
    end
  end
end
