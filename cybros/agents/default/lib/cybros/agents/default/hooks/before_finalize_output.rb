module Cybros
  module Agents
    module Default
      module Hooks
        class BeforeFinalizeOutput
          def initialize(application:)
            @application = application
          end

          def call(params:)
            {
              "actions" => [
                {
                  "type" => "emit_message",
                  "message" => {
                    "role" => "assistant",
                    "content" => compose_content(params),
                  },
                },
              ],
            }
          end

          private

          def compose_content(params)
            draft_output = params.dig("draft_output", "content").to_s.strip
            return draft_output unless draft_output.empty?

            summary = params.dig("planning", "step_plan", "summary").to_s.strip
            latest_user = latest_user_message(params)
            lines = []
            lines << "Bundled default agent plan: #{summary}" unless summary.empty?
            lines << "Latest user request: #{latest_user}" unless latest_user.empty?
            lines << "I will keep the Cybros-owned loop intact and respond concisely."
            lines.join("\n")
          end

          def latest_user_message(params)
            user_message = Array(params.dig("provider_input", "messages")).reverse.find do |message|
              message.is_a?(Hash) && message["role"].to_s == "user"
            end
            user_message.to_h["content"].to_s.strip
          end
        end
      end
    end
  end
end
