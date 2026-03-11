module Cybros
  module Agents
    module Default
      module Hooks
        class BeforeSubagentSpawn
          def initialize(application:)
            @application = application
          end

          def call(params:)
            {
              "actions" => [
                {
                  "type" => "set_step_status",
                  "text" => status_text(params),
                },
              ],
            }
          end

          private

          def status_text(params)
            request = params["subagent_request"].is_a?(Hash) ? params["subagent_request"] : {}
            tool_name = request["tool_name"].to_s.strip

            lines = ["Preparing delegated subagent work"]
            lines << "Tool: #{tool_name}" unless tool_name.empty?
            lines.join(" | ")
          end
        end
      end
    end
  end
end
