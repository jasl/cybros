module Conduits
  # Shared helpers for reading typed configuration from environment variables
  # with safe fallback defaults. Used by cleanup jobs.
  module EnvConfigurable
    extend ActiveSupport::Concern

    private

    def env_int(name, default)
      Integer(ENV.fetch(name, default))
    rescue ArgumentError, TypeError
      default
    end

    def env_float(name, default)
      Float(ENV.fetch(name, default))
    rescue ArgumentError, TypeError
      default
    end
  end
end
