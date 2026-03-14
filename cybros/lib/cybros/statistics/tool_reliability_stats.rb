module Cybros
  module Statistics
    class ToolReliabilityStats
      DEFAULT_SAMPLE_ORIGIN = "runtime"
      MODEL_FAILURE_READINESS_VALUES = %w[invalid_args tool_not_found].freeze
      SIDE_OUTCOME_READINESS_VALUES = %w[policy_denied awaiting_approval approval_rejected].freeze
      REPAIR_ASSISTED_MODEL_ATTEMPT_CLASSES = %w[repaired_name repaired_args repaired_both].freeze

      class << self
        def snapshot(sample_origin: DEFAULT_SAMPLE_ORIGIN, scope: nil)
          new(sample_origin: sample_origin, scope: scope).snapshot
        end
      end

      def initialize(sample_origin: DEFAULT_SAMPLE_ORIGIN, scope: nil)
        @sample_origin = sample_origin.to_s.presence || DEFAULT_SAMPLE_ORIGIN
        @scope = scope || ::Statistics::ToolCallFact.all
      end

      def snapshot
        {
          "summary" => build_summary(filtered_scope),
          "by_model_ref" => grouped_rows(filtered_scope, group_key: :model_ref, label_key: "model_ref"),
          "by_tool_name" => grouped_rows(filtered_scope, group_key: :resolved_name, label_key: "resolved_name"),
          "by_logical_tool_name" => grouped_rows(filtered_scope, group_key: :logical_tool_name, label_key: "logical_tool_name"),
          "by_implementation_source" => grouped_rows(filtered_scope, group_key: :implementation_source, label_key: "implementation_source"),
          "by_tool_surface_id" => grouped_rows(filtered_scope, group_key: :tool_surface_id, label_key: "tool_surface_id"),
          "by_recognized_deployment_key" => grouped_rows(filtered_scope, group_key: :recognized_deployment_key, label_key: "recognized_deployment_key"),
          "by_agent_capabilities_version" => grouped_rows(filtered_scope, group_key: :agent_capabilities_version, label_key: "agent_capabilities_version"),
          "by_failure_class" => failure_class_rows(filtered_scope),
          "by_day" => day_rows(filtered_scope),
          "by_execution_scope" => execution_scope_rows(filtered_scope),
        }
      end

      private

        attr_reader :scope, :sample_origin

        def filtered_scope
          scope.where(sample_origin: sample_origin)
        end

        def grouped_rows(base_scope, group_key:, label_key:)
          values =
            base_scope
              .pluck(group_key)
              .compact
              .map { |value| value.is_a?(String) ? value.presence : value }
              .compact
              .uniq

          rows =
            values.map do |value|
              build_summary(base_scope.where(group_key => value)).merge(label_key => value)
            end

          rows.sort_by do |row|
            [-row.fetch("total_calls"), row.fetch(label_key).to_s]
          end
        end

        def day_rows(base_scope)
          values =
            base_scope
              .where.not(effective_on: nil)
              .pluck(:effective_on)
              .compact
              .uniq
              .sort

          values.map do |value|
            build_summary(base_scope.where(effective_on: value)).merge("date" => value.to_s)
          end
        end

        def failure_class_rows(base_scope)
          base_scope
            .where(tool_outcome: "failed")
            .where.not(failure_class: [nil, ""])
            .group(:failure_class)
            .count
            .map do |failure_class, count|
              {
                "failure_class" => failure_class,
                "count" => count,
              }
            end
            .sort_by { |row| [-row.fetch("count"), row.fetch("failure_class")] }
        end

        def execution_scope_rows(base_scope)
          order = {
            "parent" => 0,
            "subagent" => 1,
          }

          grouped_rows(base_scope, group_key: :execution_scope, label_key: "execution_scope")
            .sort_by { |row| [order.fetch(row.fetch("execution_scope"), 99), row.fetch("execution_scope")] }
        end

        def build_summary(base_scope)
          model_scope = base_scope.where(manual_retry: false)
          tool_scope = base_scope.where(entered_execution: true)

          {
            "total_calls" => base_scope.count,
            "model_attempts" => model_scope.count,
            "tool_executions" => tool_scope.count,
            "result_status" => result_status_counts(base_scope),
            "latency_ms" => latency_summary(tool_scope),
            "executable_rate" => rate_row(model_scope.where(execution_readiness: "executable").count, model_scope.count),
            "first_pass_success_rate" => rate_row(model_scope.where(model_attempt_class: "first_pass", tool_outcome: "success").count, model_scope.count),
            "repair_assisted_success_rate" => rate_row(model_scope.where(model_attempt_class: REPAIR_ASSISTED_MODEL_ATTEMPT_CLASSES, tool_outcome: "success").count, model_scope.count),
            "tool_success_rate" => rate_row(tool_scope.where(tool_outcome: "success").count, tool_scope.count),
            "model_failures" => readiness_counts(model_scope, MODEL_FAILURE_READINESS_VALUES),
            "side_outcomes" => readiness_counts(model_scope, SIDE_OUTCOME_READINESS_VALUES),
          }
        end

        def readiness_counts(base_scope, readiness_values)
          counts = base_scope.where(execution_readiness: readiness_values).group(:execution_readiness).count

          readiness_values.each_with_object({ "total" => 0 }) do |value, memo|
            count = counts[value].to_i
            memo[value] = count
            memo["total"] += count
          end
        end

        def rate_row(count, total)
          {
            "count" => count,
            "total" => total,
            "value" => total.positive? ? count.to_f / total : nil,
          }
        end

        def result_status_counts(base_scope)
          counts = base_scope.group(:tool_outcome).count

          ::Statistics::ToolCallFact::TOOL_OUTCOMES.each_with_object({ "total" => 0 }) do |value, memo|
            count = counts[value].to_i
            memo[value] = count
            memo["total"] += count
          end
        end

        def latency_summary(base_scope)
          values = base_scope.where.not(duration_ms: nil).pluck(:duration_ms).map(&:to_i)
          return { "count" => 0, "avg" => nil, "max" => nil } if values.empty?

          {
            "count" => values.length,
            "avg" => (values.sum.to_f / values.length).round,
            "max" => values.max,
          }
        end
    end
  end
end
