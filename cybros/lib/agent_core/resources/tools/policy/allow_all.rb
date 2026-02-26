module AgentCore
  module Resources
    module Tools
      module Policy
        # Allows all tool visibility and execution.
        #
        # Useful for development and tests where explicit intent is preferred.
        class AllowAll < Base
          def filter(tools:, context:)
            tools
          end

          def authorize(name:, arguments:, context:)
            Decision.allow
          end
        end
      end
    end
  end
end
