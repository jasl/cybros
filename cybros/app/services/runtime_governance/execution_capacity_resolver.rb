module RuntimeGovernance
  class ExecutionCapacityResolver
    OVERRIDE_FIELDS = %i[
      max_concurrent_tasks_override
      max_queued_tasks_override
      default_timeout_s_override
      cpu_limit_millicores_override
      memory_limit_mb_override
    ].freeze

    def self.resolve!(execution_target:)
      new(execution_target: execution_target).resolve!
    end

    def initialize(execution_target:)
      @execution_target = execution_target
    end

    def resolve!
      target = execution_target
      if target.blank?
        AgentCore::ValidationError.raise!(
          "Execution target is required for programmable execution.",
          code: "cybros.runtime_governance.execution_target_missing",
          details: {},
        )
      end

      location = target.execution_location
      override_applied = override_applied?(target)

      {
        "scope_type" => override_applied ? "execution_target" : "execution_location",
        "scope_id" => override_applied ? target.id : location.id,
        "execution_location_id" => location.id,
        "execution_target_id" => target.id,
        "override_applied" => override_applied,
        "max_concurrent_tasks" => target.max_concurrent_tasks_override || location.max_concurrent_tasks,
        "max_queued_tasks" => target.max_queued_tasks_override || location.max_queued_tasks,
        "default_timeout_s" => target.default_timeout_s_override || location.default_timeout_s,
        "cpu_limit_millicores" => target.cpu_limit_millicores_override || location.cpu_limit_millicores,
        "memory_limit_mb" => target.memory_limit_mb_override || location.memory_limit_mb,
      }
    end

    private

      attr_reader :execution_target

      def override_applied?(target)
        OVERRIDE_FIELDS.any? { |field| target.public_send(field).present? }
      end
  end
end
