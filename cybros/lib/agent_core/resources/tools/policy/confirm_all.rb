module AgentCore
  module Resources
    module Tools
      module Policy
        # Confirms all tool executions while keeping tools visible.
        #
        # Useful as a safe delegate for rule-based policies where unmatched
        # tools should still be available to the LLM, but require human approval
        # before execution.
        class ConfirmAll < Base
          def initialize(reason: "needs_approval", required: false, deny_effect: nil)
            @reason = reason.to_s.strip
            @reason = "needs_approval" if @reason.empty?
            @required = required == true
            @deny_effect = deny_effect
          end

          def filter(tools:, context:)
            _ = context
            tools
          end

          def authorize(name:, arguments:, context:)
            _ = name
            _ = arguments
            _ = context

            Decision.confirm(reason: @reason, required: @required, deny_effect: @deny_effect)
          end
        end
      end
    end
  end
end
