module Agents
  class WorkspaceBootstrap
    def self.seed!(source_root:, destination_root:)
      ensure_claw_library_loaded!

      Cybros::Agents::Claw::WorkspaceBootstrap.seed!(
        source_root: source_root,
        destination_root: destination_root,
      )
    end

    def self.ensure_claw_library_loaded!
      return if claw_bootstrap_ready?

      load_claw_support_file!("daily_memory_target") unless defined?(Cybros::Agents::Claw::DailyMemoryTarget)
      load_claw_support_file!("workspace_bootstrap") unless defined?(Cybros::Agents::Claw::WorkspaceBootstrap)

      return if claw_bootstrap_ready?

      Cybros::Agents::Claw::WorkspaceBootstrap
    end

    def self.claw_bootstrap_ready?
      defined?(Cybros::Agents::Claw::DailyMemoryTarget) &&
        defined?(Cybros::Agents::Claw::WorkspaceBootstrap)
    end

    def self.claw_support_file_path_for(basename)
      Rails.root.join("../agents/claw/lib/cybros/agents/claw/#{basename}.rb").expand_path.to_s
    end

    def self.load_claw_support_file!(basename)
      load claw_support_file_path_for(basename)
    end
  end
end
