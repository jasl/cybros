module RuntimeGovernance
  class ExecutionQuotaEnforcer
    REQUIRED_QUOTA_FIELDS = %w[
      scope_type
      scope_id
      execution_location_id
      execution_target_id
      max_concurrent_tasks
      max_queued_tasks
    ].freeze

    def self.admit!(conversation_run:, now: Time.current)
      new(conversation_run: conversation_run).admit!(now: now)
    end

    def self.release!(conversation_run:, now: Time.current)
      new(conversation_run: conversation_run).release!(now: now)
    end

    def self.reconcile!(conversation_run:, now: Time.current)
      new(conversation_run: conversation_run).reconcile!(now: now)
    end

    def initialize(conversation_run:)
      @conversation_run = conversation_run
    end

    def admit!(now:)
      quota = execution_quota_snapshot
      execution_request_id = execution_request_id_for

      result =
        ExecutionCapacityLeases.acquire!(
          quota: quota,
          execution_request_id: execution_request_id,
          holder_type: conversation_run.class.name,
          holder_id: conversation_run.id.to_s,
          now: now,
        )

      result.merge(execution_request_id: execution_request_id, quota: quota)
    end

    def release!(now:)
      quota = execution_quota_snapshot

      ExecutionCapacityLeases.release!(
        subject_type: quota.fetch("scope_type"),
        subject_id: quota.fetch("scope_id"),
        execution_request_id: execution_request_id_for,
        now: now,
      )
    end

    def reconcile!(now:)
      quota = execution_quota_snapshot

      ExecutionCapacityLeases.reconcile_expired!(
        subject_type: quota.fetch("scope_type"),
        subject_id: quota.fetch("scope_id"),
        now: now,
      )
    end

    private

      attr_reader :conversation_run

      def execution_quota_snapshot
        runtime_governors =
          if conversation_run.respond_to?(:runtime_governors)
            conversation_run.runtime_governors
          end
        snapshot =
          if runtime_governors.is_a?(Hash)
            runtime_governors["execution_quota"] || runtime_governors[:execution_quota]
          end

        unless snapshot.is_a?(Hash)
          AgentCore::ValidationError.raise!(
            "Execution quota snapshot missing",
            code: "cybros.runtime_governance.execution_quota_snapshot_missing",
            details: { conversation_run_id: conversation_run.id.to_s },
          )
        end

        snapshot = snapshot.deep_stringify_keys
        missing_fields = REQUIRED_QUOTA_FIELDS.select { |field| snapshot[field].blank? }
        return snapshot if missing_fields.empty?

        AgentCore::ValidationError.raise!(
          "Execution quota snapshot invalid",
          code: "cybros.runtime_governance.execution_quota_snapshot_invalid",
          details: {
            conversation_run_id: conversation_run.id.to_s,
            missing_fields: missing_fields,
          },
        )
      end

      def execution_request_id_for
        "conversation_run:#{conversation_run.id}"
      end
  end
end
