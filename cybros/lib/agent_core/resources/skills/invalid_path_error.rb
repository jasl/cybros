# frozen_string_literal: true

module AgentCore
  module Resources
    module Skills
      # Raised when a skill path is invalid (absolute paths, traversal, symlink
      # escapes, or paths outside allowed directories).
      class InvalidPathError < AgentCore::ValidationError; end
    end
  end
end
