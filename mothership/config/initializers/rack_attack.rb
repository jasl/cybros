require "rack/attack"

# NOTE: This project uses Rack::Attack for minimal API hardening.
# Phase 0.5: only enrollment is rate-limited (per-IP) to reduce token brute-force / DoS risk.

store = Rails.cache
if store.is_a?(ActiveSupport::Cache::NullStore)
  store = ActiveSupport::Cache::MemoryStore.new
end
Rack::Attack.cache.store = store

# POST /conduits/v1/territories/enroll — 10 requests / hour / IP
Rack::Attack.throttle("conduits/territories/enroll/ip", limit: 10, period: 1.hour) do |req|
  if req.post? && req.path == "/conduits/v1/territories/enroll"
    req.ip
  end
end

# POST /conduits/v1/polls — 60 requests / minute / territory (allow ~1/s burst)
Rack::Attack.throttle("conduits/polls/territory", limit: 60, period: 1.minute) do |req|
  if req.post? && req.path == "/conduits/v1/polls"
    req.get_header("HTTP_X_NEXUS_TERRITORY_ID") || req.ip
  end
end

# POST /conduits/v1/territories/heartbeat — 10 requests / minute / territory
Rack::Attack.throttle("conduits/territories/heartbeat/territory", limit: 10, period: 1.minute) do |req|
  if req.post? && req.path == "/conduits/v1/territories/heartbeat"
    req.get_header("HTTP_X_NEXUS_TERRITORY_ID") || req.ip
  end
end

# POST /conduits/v1/directives/:id/* — 120 requests / minute / IP
# Covers log_chunks, heartbeat, started, finished per territory
Rack::Attack.throttle("conduits/directives/ip", limit: 120, period: 1.minute) do |req|
  if req.post? && req.path.start_with?("/conduits/v1/directives/")
    req.get_header("HTTP_X_NEXUS_TERRITORY_ID") || req.ip
  end
end

Rack::Attack.throttled_responder = lambda do |request|
  match_data = request.env["rack.attack.match_data"] || {}
  retry_after = Integer(match_data[:period] || 1.hour)

  [
    429,
    {
      "Content-Type" => "application/json",
      "Retry-After" => retry_after.to_s,
    },
    [
      {
        error: "rate_limited",
        detail: "too many requests",
      }.to_json,
    ],
  ]
end

Rails.application.config.middleware.use Rack::Attack
