module Agents
  class WorkspacePathResolver
    def self.resolve(agent:)
      new(agent: agent).resolve
    end

    def initialize(agent:)
      @agent = agent
    end

    def resolve
      RuntimeSetting.agent_workspace_root_path_for(agent: agent).cleanpath
    end

    private

      attr_reader :agent
  end
end
