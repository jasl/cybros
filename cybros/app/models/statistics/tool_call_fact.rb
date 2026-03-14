module Statistics
  class ToolCallFact < ApplicationRecord
    self.table_name = "statistics_tool_call_facts"

    belongs_to :recognized_deployment, optional: true

    SAMPLE_ORIGINS = %w[runtime eval debug replay].freeze
    EXECUTION_SCOPES = %w[parent subagent].freeze
    MODEL_ATTEMPT_CLASSES = %w[first_pass repaired_name repaired_args repaired_both].freeze
    EXECUTION_READINESS_VALUES = %w[executable invalid_args tool_not_found policy_denied awaiting_approval approval_rejected].freeze
    TOOL_OUTCOMES = %w[success failed not_executed].freeze
    FAILURE_CLASSES = %w[validation_error implementation_error remote_api_error timeout rate_limit auth unknown].freeze

    validates :task_node_id, presence: true, uniqueness: true
    validates :conversation_id, presence: true
    validates :root_conversation_id, presence: true
    validates :graph_id, presence: true
    validates :turn_id, presence: true
    validates :sample_origin, presence: true, inclusion: { in: SAMPLE_ORIGINS }
    validates :execution_scope, presence: true, inclusion: { in: EXECUTION_SCOPES }
    validates :model_attempt_class, presence: true, inclusion: { in: MODEL_ATTEMPT_CLASSES }
    validates :execution_readiness, presence: true, inclusion: { in: EXECUTION_READINESS_VALUES }
    validates :tool_outcome, presence: true, inclusion: { in: TOOL_OUTCOMES }
    validates :failure_class, allow_nil: true, inclusion: { in: FAILURE_CLASSES }
    validates :duration_ms, allow_nil: true, numericality: { greater_than_or_equal_to: 0, only_integer: true }
    validates :recognized_deployment_key, presence: true, if: :recognized_deployment_id?

    before_validation :derive_effective_on
    before_validation :derive_duration_ms
    before_validation :derive_recognized_deployment_key

    private

      def derive_effective_on
        return if effective_on.present?

        reference_time = finished_at || started_at
        self.effective_on = reference_time.to_date if reference_time.present?
      end

      def derive_duration_ms
        return if duration_ms.present?
        return if started_at.blank? || finished_at.blank?

        self.duration_ms = ((finished_at - started_at) * 1000).round
      end

      def derive_recognized_deployment_key
        return if recognized_deployment_key.present?

        self.recognized_deployment_key = recognized_deployment&.recognized_deployment_key
      end
  end
end
