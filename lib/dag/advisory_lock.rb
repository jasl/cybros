module DAG
  module AdvisoryLock
    LOCK_PREFIX = "dag:advisory".freeze

    def self.with_try_lock(key, timeout_seconds: 0)
      lock_name = "#{LOCK_PREFIX}:#{key}"
      acquired = false

      Conversation.with_advisory_lock(lock_name, timeout_seconds: timeout_seconds) do
        acquired = true
        yield
      end

      acquired
    end
  end
end
