module Agents
  class WorkspaceBootstrap
    def self.seed!(source_root:, destination_root:)
      require "cybros/agents/claw"

      Cybros::Agents::Claw::WorkspaceBootstrap.seed!(
        source_root: source_root,
        destination_root: destination_root,
      )
    end
  end
end
