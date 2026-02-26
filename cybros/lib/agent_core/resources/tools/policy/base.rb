module AgentCore
  module Resources
    module Tools
      module Policy
        # Abstract base class for tool access policies.
        #
        # Policies control which tools are visible to the LLM and whether
        # specific tool calls are authorized. The app implements policies
        # based on its authorization model.
        class Base
          # Filter the list of tool definitions before sending to the LLM.
          #
          # @param tools [Array<Hash>] Tool definitions
          # @param context [AgentCore::ExecutionContext] Execution context
          # @return [Array<Hash>] Filtered tool definitions
          def filter(tools:, context:)
            tools # Default: no filtering
          end

          # Authorize a specific tool call.
          #
          # @param name [String] Executed tool name (resolved name that will actually be executed)
          # @param arguments [Hash] Tool arguments
          # @param context [AgentCore::ExecutionContext] Execution context
          # @return [Decision]
          def authorize(name:, arguments: {}, context:)
            Decision.allow # Default: allow all
          end
        end
      end
    end
  end
end
