require "digest"

module DAG
  module AdvisoryLock
    def self.with_try_lock(key)
      key_1, key_2 = keys_for(key)
      ActiveRecord::Base.with_connection do |connection|
        obtained = connection.select_value("SELECT pg_try_advisory_lock(#{key_1}, #{key_2})")
        if obtained
          begin
            yield
            true
          ensure
            connection.select_value("SELECT pg_advisory_unlock(#{key_1}, #{key_2})")
          end
        else
          false
        end
      end
    end

    def self.keys_for(key)
      digest = Digest::SHA256.digest(key.to_s)
      digest.unpack("l>l>")
    end
  end
end
