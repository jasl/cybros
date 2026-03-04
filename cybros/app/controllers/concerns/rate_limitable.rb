module RateLimitable
  extend ActiveSupport::Concern

  private

    def throttle!(key:, limit:, period:)
      identity = Current.user&.id || request.remote_ip
      window = Time.current.to_i / period.to_i
      cache_key = "throttle:#{key}:#{identity}:#{window}"

      # `increment` returns nil for missing keys unless `initial` is provided (e.g. MemoryStore).
      count = Rails.cache.increment(cache_key, 1, expires_in: period + 5, initial: 0)
      return if count.nil? || count <= limit

      head :too_many_requests
    end
end
