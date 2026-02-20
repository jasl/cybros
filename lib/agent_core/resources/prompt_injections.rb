# frozen_string_literal: true

module AgentCore
  module Resources
    module PromptInjections
      TARGETS = [:system_section, :preamble_message].freeze
      ROLES = [:user, :assistant].freeze
      PROMPT_MODES = [:full, :minimal].freeze
    end
  end
end
