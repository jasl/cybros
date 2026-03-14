module RuntimeGovernance
  class ExecutionCapacityResolver
    def self.resolve!(agent:)
      new(agent: agent).resolve!
    end

    def initialize(agent:)
      @agent = agent
    end

    def resolve!
      if agent.blank?
        AgentCore::ValidationError.raise!(
          "Agent execution capacity is required for programmable execution.",
          code: "cybros.runtime_governance.execution_capacity_missing",
          details: {},
        )
      end

      {
        "scope_type" => "agent",
        "scope_id" => agent.id,
        "max_concurrent_tasks" => agent.max_concurrent_tasks,
        "max_queued_tasks" => agent.max_queued_tasks,
        "default_timeout_s" => agent.default_timeout_s,
        "cpu_limit_millicores" => agent.cpu_limit_millicores,
        "memory_limit_mb" => agent.memory_limit_mb,
      }.compact
    end

    private

      attr_reader :agent
  end
end
