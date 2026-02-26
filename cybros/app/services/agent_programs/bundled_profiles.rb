# frozen_string_literal: true

module AgentPrograms
  module BundledProfiles
    PROFILE_ROOT = Rails.root.join("cybros-agent", "profiles").freeze

    module_function

    def available
      return [] unless PROFILE_ROOT.directory?

      PROFILE_ROOT.children.select(&:directory?).map(&:basename).map(&:to_s).sort
    rescue StandardError
      []
    end

    def profile_path(profile_source)
      name = profile_source.to_s.strip
      return nil if name.empty?

      candidate = PROFILE_ROOT.join(name)
      return nil unless candidate.directory?

      candidate
    rescue StandardError
      nil
    end
  end
end

