module Cybros
  module Agents
    module Default
      module Hooks
        class OnLaneFirstUserMessage
          def initialize(application:)
            @application = application
          end

          def call(params:)
            return { "actions" => [{ "type" => "noop" }] } unless params["agent_key"].to_s == "main"

            user_node_id = params["user_node_id"]
            actions = [build_task("cybros_generate_title", params:, user_node_id:)]
            actions << build_summary_task(params:) if branch_lane?(params)

            { "actions" => actions }
          end

          private

            def build_task(logical_tool_name, params:, user_node_id:)
              {
                "type" => "create_task",
                "logical_tool_name" => logical_tool_name,
                "input" => {
                  "conversation_id" => params["conversation_id"],
                  "lane_id" => params["lane_id"],
                  "user_node_id" => user_node_id,
                }.compact,
                "placement" => "append",
                "metadata" => {
                  "leaf_terminal" => true,
                },
              }
            end

            def build_summary_task(params:)
              {
                "type" => "create_task",
                "logical_tool_name" => "cybros_enqueue_lane_summary",
                "input" => {
                  "conversation_id" => params["conversation_id"],
                  "lane_id" => params["lane_id"],
                }.compact,
                "placement" => "append",
                "metadata" => {
                  "leaf_terminal" => true,
                },
              }
            end

            def branch_lane?(params)
              params["lane_role"].to_s == "branch" || params["conversation_kind"].to_s == "branch"
            end
        end
      end
    end
  end
end
