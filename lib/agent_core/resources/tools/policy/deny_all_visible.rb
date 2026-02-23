# frozen_string_literal: true

module AgentCore
  module Resources
    module Tools
      module Policy
        # Denies all tool execution while keeping tools visible.
        #
        # This is useful for "dontAsk" style defaults where tools should be
        # visible to the LLM (for planning / transparency), but execution is
        # denied unless a more-specific allow policy matches upstream.
        class DenyAllVisible < Base
          def initialize(reason: "tool access denied")
            @reason = reason.to_s.strip
            @reason = "tool access denied" if @reason.empty?
          end

          def filter(tools:, context:)
            _ = context
            tools
          end

          def authorize(name:, arguments:, context:)
            _ = name
            _ = arguments
            _ = context

            Decision.deny(reason: @reason)
          end
        end
      end
    end
  end
end
