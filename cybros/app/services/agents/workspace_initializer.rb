module Agents
  class WorkspaceInitializer
    def self.initialize!(agent:)
      new(agent: agent).initialize!
    end

    def initialize(agent:)
      @agent = agent
    end

    def initialize!
      root_path.mkpath
      if bootstrap_source_root?
        Agents::WorkspaceBootstrap.seed!(source_root: agent.absolute_local_path, destination_root: root_path)
      end

      {
        agent_id: agent.id,
        root_path: root_path.to_s,
      }
    end

    private

      attr_reader :agent

      def root_path
        Agents::WorkspacePathResolver.resolve(agent: agent)
      end

      def bootstrap_source_root?
        agent.bundled_source? && agent.absolute_local_path.join("prompts").directory?
      end
  end
end
