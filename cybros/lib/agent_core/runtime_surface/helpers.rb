module AgentCore
  module RuntimeSurface
    class Helpers
      ALLOWED_KEYS = %i[estimate_tokens].freeze

      def initialize(callables: {})
        raw = callables.nil? ? {} : callables
        AgentCore::ValidationError.raise!(
          "runtime surface helpers must be a Hash",
          code: "agent_core.runtime_surface.helpers.helpers_must_be_a_hash",
          details: { value_class: raw.class.name },
        ) unless raw.is_a?(Hash)

        normalized = raw.each_with_object({}) do |(key, value), out|
          name = key.to_sym
          unless ALLOWED_KEYS.include?(name)
            AgentCore::ValidationError.raise!(
              "runtime surface helper #{name.inspect} is not supported",
              code: "agent_core.runtime_surface.helpers.helper_is_not_supported",
              details: { helper: name.to_s },
            )
          end

          unless value.respond_to?(:call)
            AgentCore::ValidationError.raise!(
              "runtime surface helper #{name.inspect} must respond to #call",
              code: "agent_core.runtime_surface.helpers.helper_must_respond_to_call",
              details: { helper: name.to_s, helper_class: value.class.name },
            )
          end

          out[name] = value
        end

        @callables = normalized.freeze
      end

      def scope(execution_context:, stage:)
        Scope.new(callables: @callables, execution_context: execution_context, stage: stage)
      end

      class Scope
        def initialize(callables:, execution_context:, stage:)
          @callables = callables
          @execution_context = execution_context
          @stage = stage.to_sym
        end

        def estimate_tokens(text)
          call_helper(:estimate_tokens, text)
        end

        private

          def call_helper(name, *args)
            callable = @callables.fetch(name, nil)
            raise Errors::HelperUnavailable, "runtime surface helper #{name} is unavailable" if callable.nil?

            if accepts_keywords?(callable)
              callable.call(*args, context: @execution_context, stage: @stage)
            else
              callable.call(*args)
            end
          end

          def accepts_keywords?(callable)
            callable.parameters.any? { |kind, _| %i[key keyreq keyrest].include?(kind) }
          rescue StandardError
            false
          end
      end
    end
  end
end
