require_relative "runtime_surface/decisions"
require_relative "runtime_surface/errors"
require_relative "runtime_surface/helpers"
require_relative "runtime_surface/inputs"
require_relative "runtime_surface/base"
require_relative "runtime_surface/runner"
require_relative "runtime_surface/audit_serializer"
require_relative "runtime_surface/tool_result_projection"

module AgentCore
  module RuntimeSurface
    LIFECYCLE_METHODS = %i[
      prepare_turn
      compact_context
      review_tool_call
      project_tool_result
      finalize_output
      handle_error
    ].freeze

    DEFAULT = Base.new.freeze

    module_function

    def default
      DEFAULT
    end

    def validate!(surface)
      candidate = surface || default

      LIFECYCLE_METHODS.each do |method_name|
        next if candidate.respond_to?(method_name)

        AgentCore::ValidationError.raise!(
          "runtime_surface must respond to ##{method_name}",
          code: "agent_core.runtime_surface.surface_must_respond_to_lifecycle_method",
          details: { method: method_name.to_s, runtime_surface_class: candidate.class.name },
        )
      end

      candidate
    end
  end
end
