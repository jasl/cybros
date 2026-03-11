module Cybros
  module Agents
    module Default
      module Hooks
        class AfterSubagentResult
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
            result = params["subagent_result"].is_a?(Hash) ? params["subagent_result"] : {}
            subagent_id = result["subagent_id"].to_s.strip
            status = result["status"].to_s.strip
            candidate = result["assistant_output_candidate"].is_a?(Hash) ? result["assistant_output_candidate"] : {}
            candidate_scope = candidate["scope"].to_s.strip

            lines = []
            lines << "Summarizing subagent results"
            lines << "Subagent: #{subagent_id}" unless subagent_id.empty?
            lines << "Status: #{status}" unless status.empty?
            lines << "Candidate scope: #{candidate_scope}" unless candidate_scope.empty?
            lines.join(" | ")
          end
        end
      end
    end
  end
end
