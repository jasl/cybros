module Cybros
  module Agents
    module Claw
      module Hooks
        class OnConversationCreated
          def initialize(application:)
            @application = application
          end

          def call(params:)
            return { "actions" => [ { "type" => "noop" } ] } unless params["conversation_kind"].to_s == "root"
            return { "actions" => [ { "type" => "noop" } ] } unless params["agent_key"].to_s == "main"

            {
              "actions" => [
                {
                  "type" => "create_task",
                  "logical_tool_name" => "cybros_seed_message",
                  "input" => {
                    "conversation_id" => params["conversation_id"],
                    "lane_id" => params["lane_id"],
                    "role" => "assistant",
                    "content" => "I’m Cybros. I’ll track state in the DAG and keep follow-up work explicit.",
                    "exclude_from_context" => true
                  }.compact,
                  "placement" => "append"
                }
              ]
            }
          end
        end
      end
    end
  end
end
