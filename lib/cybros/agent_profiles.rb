# frozen_string_literal: true

module Cybros
  module AgentProfiles
    DEFAULT_PROFILE = "full"

    PROFILES = {
      "full" => ["*"],
      "minimal" => [],
      "memory_only" => ["memory_*"],
      "skills_only" => ["skills_*"],
    }.freeze

    module_function

    def normalize(value)
      s = value.to_s.strip.downcase
      s = DEFAULT_PROFILE if s.empty?

      PROFILES.key?(s) ? s : DEFAULT_PROFILE
    rescue StandardError
      DEFAULT_PROFILE
    end

    def allowed_patterns(profile)
      PROFILES.fetch(normalize(profile))
    rescue StandardError
      PROFILES.fetch(DEFAULT_PROFILE)
    end

    def valid?(profile)
      PROFILES.key?(profile.to_s.strip.downcase)
    rescue StandardError
      false
    end
  end
end

