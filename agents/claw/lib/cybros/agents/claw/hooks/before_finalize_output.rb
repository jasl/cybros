module Cybros
  module Agents
    module Claw
      module Hooks
        class BeforeFinalizeOutput
          SILENT_REPLY_TOKEN = "NO_REPLY"

          def initialize(application:)
            @application = application
          end

          def call(params:)
            draft_content = params.dig("draft_output", "content").to_s
            return { "actions" => [ { "type" => "finish_silently", "reason" => "silent_reply" } ] } if silent_reply_text?(draft_content)

            content = compose_content(params)
            return { "actions" => [ { "type" => "finish_silently", "reason" => "silent_reply" } ] } if content.empty?

            {
              "actions" => [
                {
                  "type" => "emit_message",
                  "message" => {
                    "role" => "assistant",
                    "content" => content
                  }
                }
              ]
            }
          end

          private

          def compose_content(params)
            draft_output = strip_silent_token(params.dig("draft_output", "content").to_s)
            return draft_output unless draft_output.empty?

            summary = params.dig("planning", "step_plan", "summary").to_s.strip
            latest_user = latest_user_message(params)
            lines = []
            lines << "Bundled claw agent plan: #{summary}" unless summary.empty?
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

          def silent_reply_text?(text)
            text.to_s.match?(/\A\s*#{Regexp.escape(SILENT_REPLY_TOKEN)}\s*\z/)
          end

          def strip_silent_token(text)
            text.to_s.gsub(/(?:^|\s+|\*+)#{Regexp.escape(SILENT_REPLY_TOKEN)}\s*\z/, "").strip
          end
        end
      end
    end
  end
end
