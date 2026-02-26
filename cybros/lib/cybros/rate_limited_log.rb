module Cybros
  module RateLimitedLog
    @mutex = Mutex.new
    @last_warn_at = {}

    module_function

    # Defensive sanitizer for anything that could be influenced by external input
    # (e.g., exception messages that may embed user-provided strings).
    #
    # - Removes newlines/tabs to prevent log forging
    # - Truncates to bound log volume
    # - Ensures valid UTF-8
    def sanitize(value, max_bytes: 500)
      s = value.to_s
      s = s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
      s = s.tr("\r\n\t", "   ")
      s = s.strip

      return s if s.bytesize <= max_bytes

      "#{s.byteslice(0, max_bytes)}…"
    rescue StandardError
      ""
    end

    def warn(key, interval_s: 10, message: nil, logger: Rails.logger, now: Time.current.to_f)
      should_log = false

      @mutex.synchronize do
        last = @last_warn_at[key]
        if last.nil? || (now - last) >= interval_s
          @last_warn_at[key] = now
          should_log = true
        end
      end

      return unless should_log

      if message
        logger.warn(message)
      else
        logger.warn(key.to_s)
      end
    rescue StandardError
      nil
    end
  end
end
