# frozen_string_literal: true

module AgentCore
  module Resources
    module Tools
      class ToolNameConflictError < AgentCore::ValidationError
        attr_reader :tool_name, :existing_source, :new_source

        def initialize(message = nil, tool_name: nil, existing_source: nil, new_source: nil, details: {})
          @tool_name = tool_name&.to_s
          @existing_source = existing_source
          @new_source = new_source
          super(message, code: "tool_name_conflict", details: details || {})
        end
      end
    end
  end
end
