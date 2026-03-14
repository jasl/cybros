module Cybros
  module Agents
    module Claw
      module Hooks
        class AfterTaskNotice
          def initialize(application:)
            @application = application
          end

          def call(params:)
            if task_subject_kind(params) == "task"
              {
                "actions" => [
                  {
                    "type" => "set_step_status",
                    "text" => task_status_text(params),
                    "state" => "running"
                  }
                ]
              }
            else
              {
                "actions" => [
                  {
                    "type" => "emit_message",
                    "message" => {
                      "role" => "assistant",
                      "content" => agent_step_message_text(params)
                    }
                  }
                ]
              }
            end
          end

          private

          def task_subject_kind(params)
            value = params.dig("task_notice", "subject_kind").to_s.strip
            value.empty? ? "agent_step" : value
          end

          def task_status_text(params)
            notice_kind = params.dig("task_notice", "notice", "kind").to_s.strip
            logical_tool_name = params.dig("task_notice", "logical_tool_name").to_s.strip
            error_message = params.dig("task_notice", "error", "message").to_s.strip

            [
              ("Task notice: #{notice_kind}" unless notice_kind.empty?),
              ("Tool: #{logical_tool_name}" unless logical_tool_name.empty?),
              ("Error: #{error_message}" unless error_message.empty?)
            ].compact.join(" | ")
          end

          def agent_step_message_text(params)
            summary = params.dig("planning", "step_plan", "summary").to_s.strip
            latest_user = latest_user_message(params)
            notice_kind = params.dig("task_notice", "notice", "kind").to_s.strip
            error_message = params.dig("task_notice", "error", "message").to_s.strip

            [
              ("Bundled claw agent could not finish while trying to #{summary}" unless summary.empty?),
              ("Latest user request: #{latest_user}" unless latest_user.empty?),
              ("Task notice: #{notice_kind}" unless notice_kind.empty?),
              ("Reported error: #{error_message}" unless error_message.empty?)
            ].compact.join("\n")
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
