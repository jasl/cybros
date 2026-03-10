# frozen_string_literal: true

module Cybros
  module Agents
    module Default
      module Hooks
        class HandleError
          def initialize(application:)
            @application = application
          end

          def call(params:)
            summary = params.dig("prepared_plan", "summary").to_s.strip
            latest_user = latest_user_message(params)
            error_message = params.dig("error", "message").to_s.strip

            {
              "output" => {
                "role" => "assistant",
                "content" => [
                  ("Bundled default agent hit an error while trying to #{summary}" unless summary.empty?),
                  ("Latest user request: #{latest_user}" unless latest_user.empty?),
                  ("Reported error: #{error_message}" unless error_message.empty?),
                ].compact.join("\n"),
              },
            }
          end

          private

          def latest_user_message(params)
            user_message = Array(params.dig("provider_input", "messages")).reverse.find { |message| message.is_a?(Hash) && message["role"].to_s == "user" }
            user_message.to_h["content"].to_s.strip
          end
        end
      end
    end
  end
end
