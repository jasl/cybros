require "fileutils"

module AgentPrograms
  class Creator
    STORAGE_ROOT = Rails.root.join("storage", "agent_programs").freeze

    def self.create_from_profile!(name:, profile_source:)
      profile_dir = BundledProfiles.profile_path(profile_source)
      raise ArgumentError, "unknown bundled profile" if profile_dir.nil?

      timestamp = Time.current.utc.strftime("%Y%m%d%H%M%S")
      random = SecureRandom.hex(6)

      rel_dir = File.join("storage", "agent_programs", "#{timestamp}-#{random}")
      abs_dir = Rails.root.join(rel_dir)

      FileUtils.mkdir_p(abs_dir)
      FileUtils.cp_r(Dir.glob(profile_dir.join("*")), abs_dir)
      loaded = Loader.new(base_dir: abs_dir).load

      AgentProgram.create!(
        name: name,
        description: nil,
        profile_source: profile_source,
        local_path: rel_dir,
        args: {
          "runtime_surface" => loaded.runtime_surface_config,
          "runtime_surface_status" => loaded.runtime_surface_status,
        },
        active_persona: nil,
      )
    end
  end
end
