module Cybros
  module Agents
    module Claw
      module Hooks
        class OnContextPressure
          def initialize(application:)
            @application = application
          end

          def call(params:)
            context_pressure = params["context_pressure"].is_a?(Hash) ? params["context_pressure"] : {}
            budget_state = context_pressure["budget_state"].to_s.strip
            budget_action = context_pressure["budget_action"].to_s.strip

            actions = [
              {
                "type" => "set_step_status",
                "text" => status_text(budget_state: budget_state, budget_action: budget_action)
              }
            ]

            if prepend_memory_flush?(budget_action: budget_action, params: params)
              actions << {
                "type" => "create_task",
                "logical_tool_name" => "memory_store",
                "placement" => "prepend",
                "input" => {
                  "content" => memory_flush_content(budget_state: budget_state, budget_action: budget_action),
                  "mode" => "append",
                  "scope" => "conversation",
                  "target" => Conversations::LaneMemoryPromotionService.daily_log_target,
                }
              }
            end

            if prepend_compact_context?(budget_action: budget_action, params: params)
              reason = budget_state.empty? ? budget_action : budget_state
              reason = "context_pressure" if reason.to_s.empty?
              actions << {
                "type" => "create_task",
                "logical_tool_name" => "compact_context",
                "placement" => "prepend",
                "input" => {
                  "reason" => reason
                }
              }
            end

            { "actions" => actions }
          end

          private

          def status_text(budget_state:, budget_action:)
            lines = [ "Handling context pressure" ]
            lines << "State: #{budget_state}" unless budget_state.empty?
            lines << "Action: #{budget_action}" unless budget_action.empty?
            lines.join(" | ")
          end

          def prepend_compact_context?(budget_action:, params:)
            return false unless %w[advise_compact enqueue_compact].include?(budget_action)

            Array(params.dig("provider_input", "tools")).any? do |tool|
              next false unless tool.is_a?(Hash)

              logical_name = tool["logical_tool_name"].to_s
              name = tool["name"].to_s
              logical_name == "compact_context" || name == "compact_context"
            end
          end

          def prepend_memory_flush?(budget_action:, params:)
            return false unless prepend_compact_context?(budget_action: budget_action, params: params)

            Array(params.dig("provider_input", "tools")).any? do |tool|
              next false unless tool.is_a?(Hash)

              logical_name = tool["logical_tool_name"].to_s
              name = tool["name"].to_s
              logical_name == "memory_store" || name == "memory_store"
            end
          end

          def memory_flush_content(budget_state:, budget_action:)
            parts = [ "[auto-memory-flush]" ]
            parts << "budget_state=#{budget_state}" if budget_state.present?
            parts << "budget_action=#{budget_action}" if budget_action.present?
            parts << "Capture durable facts and pending work before compaction."
            parts.join(" ")
          end
        end
      end
    end
  end
end
