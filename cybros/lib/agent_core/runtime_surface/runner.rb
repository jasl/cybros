require "json"
require "timeout"

module AgentCore
  module RuntimeSurface
    class Runner
      Result =
        Data.define(
          :decision,
          :fallback,
          :failure_reason,
          :error_class,
        ) do
          def fallback?
            fallback
          end
        end

      DEFAULT_TIMEOUT_S = 0.25
      DEFAULT_MAX_OUTPUT_BYTES = 16_000

      STAGE_INPUT_TYPES = {
        prepare_turn: Inputs::PrepareTurn,
        compact_context: Inputs::CompactContext,
        review_tool_call: Inputs::ReviewToolCall,
        project_tool_result: Inputs::ProjectToolResult,
        finalize_output: Inputs::FinalizeOutput,
        handle_error: Inputs::HandleError,
      }.freeze

      STAGE_DECISION_TYPES = {
        prepare_turn: [Decisions::Pass, Decisions::TurnRewrite].freeze,
        compact_context: [Decisions::Pass, Decisions::ContextCompaction].freeze,
        review_tool_call: [Decisions::Pass, Decisions::ToolCallSuggestion].freeze,
        project_tool_result: [Decisions::Pass, Decisions::ToolResultProjection].freeze,
        finalize_output: [Decisions::Pass, Decisions::FinalOutput].freeze,
        handle_error: [Decisions::Pass, Decisions::ErrorHandling].freeze,
      }.freeze

      def initialize(helpers: nil, stage_limits: nil)
        @helpers = Helpers.new(callables: helpers || {})
        @stage_limits = normalize_stage_limits(stage_limits)
      end

      def run(surface:, stage:, input:, execution_context:)
        stage_name = normalize_stage(stage)
        surface = AgentCore::RuntimeSurface.validate!(surface)
        execution_context = AgentCore::ExecutionContext.from(execution_context)

        decision =
          execution_context.instrumenter.instrument(
            "agent_core.runtime_surface.stage",
            run_id: execution_context.run_id,
            stage: stage_name.to_s,
            runtime_surface_class: surface.class.name,
          ) do
            validate_input!(stage_name, input)

            stage_context = AgentCore::ExecutionContext.from(execution_context, runtime_surface_stage: stage_name)
            scoped_helpers = @helpers.scope(execution_context: stage_context, stage: stage_name)
            scoped_input = replace_helpers(input, scoped_helpers)
            stage_limits = @stage_limits.fetch(stage_name)

            run_with_timeout(stage_name, stage_limits.fetch(:timeout_s)) do
              decision = surface.public_send(stage_name, input: scoped_input)
              validate_decision!(stage_name, decision)
              enforce_output_limit!(stage_name, decision, stage_limits.fetch(:max_output_bytes))
            end
          end

        Result.new(decision: decision, fallback: false, failure_reason: nil, error_class: nil).tap do |result|
          AgentCore::RuntimeSurface::AuditSerializer.publish_stage(
            execution_context: execution_context,
            stage: stage_name,
            surface: surface,
            input: input,
            result: result,
          )
        end
      rescue Errors::StageTimeout => e
        fallback_result(stage_name, :timeout, e.class.name).tap do |result|
          AgentCore::RuntimeSurface::AuditSerializer.publish_stage(
            execution_context: execution_context,
            stage: stage_name,
            surface: surface,
            input: input,
            result: result,
          )
        end
      rescue Errors::OutputLimitExceeded => e
        fallback_result(stage_name, :output_limit_exceeded, e.class.name).tap do |result|
          AgentCore::RuntimeSurface::AuditSerializer.publish_stage(
            execution_context: execution_context,
            stage: stage_name,
            surface: surface,
            input: input,
            result: result,
          )
        end
      rescue StandardError => e
        fallback_result(stage_name, :error, e.class.name).tap do |result|
          AgentCore::RuntimeSurface::AuditSerializer.publish_stage(
            execution_context: execution_context,
            stage: stage_name,
            surface: surface,
            input: input,
            result: result,
          )
        end
      end

      private

        def normalize_stage(stage)
          name = stage.to_s.strip.downcase.tr("-", "_").to_sym
          return name if STAGE_INPUT_TYPES.key?(name)

          AgentCore::ValidationError.raise!(
            "runtime surface stage #{stage.inspect} is not supported",
            code: "agent_core.runtime_surface.runner.stage_is_not_supported",
            details: { stage: stage.to_s },
          )
        end

        def normalize_stage_limits(value)
          raw = value.nil? ? {} : value
          AgentCore::ValidationError.raise!(
            "runtime surface stage_limits must be a Hash",
            code: "agent_core.runtime_surface.runner.stage_limits_must_be_a_hash",
            details: { value_class: raw.class.name },
          ) unless raw.is_a?(Hash)

          STAGE_INPUT_TYPES.keys.each_with_object({}) do |stage_name, out|
            provided = raw.fetch(stage_name, raw.fetch(stage_name.to_s, {}))
            provided = {} unless provided.is_a?(Hash)

            timeout_s = normalize_positive_number(provided.fetch(:timeout_s, provided.fetch("timeout_s", DEFAULT_TIMEOUT_S)))
            max_output_bytes = normalize_positive_integer(provided.fetch(:max_output_bytes, provided.fetch("max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES)))

            out[stage_name] = {
              timeout_s: timeout_s,
              max_output_bytes: max_output_bytes,
            }.freeze
          end.freeze
        end

        def normalize_positive_number(value)
          normalized = Float(value, exception: false)
          AgentCore::ValidationError.raise!(
            "runtime surface timeout_s must be a positive number",
            code: "agent_core.runtime_surface.runner.timeout_s_must_be_a_positive_number",
            details: { value_class: value.class.name },
          ) unless normalized && normalized.positive? && normalized.finite?
          normalized
        end

        def normalize_positive_integer(value)
          normalized = Integer(value, exception: false)
          AgentCore::ValidationError.raise!(
            "runtime surface max_output_bytes must be a positive integer",
            code: "agent_core.runtime_surface.runner.max_output_bytes_must_be_a_positive_integer",
            details: { value_class: value.class.name },
          ) unless normalized && normalized.positive?
          normalized
        end

        def validate_input!(stage, input)
          expected = STAGE_INPUT_TYPES.fetch(stage)
          return if input.is_a?(expected)

          AgentCore::ValidationError.raise!(
            "runtime surface stage #{stage} expected #{expected.name}",
            code: "agent_core.runtime_surface.runner.input_must_match_stage",
            details: { stage: stage.to_s, expected_class: expected.name, actual_class: input.class.name },
          )
        end

        def validate_decision!(stage, decision)
          allowed = STAGE_DECISION_TYPES.fetch(stage)
          return decision if allowed.any? { |klass| decision.is_a?(klass) }

          raise Errors::InvalidDecision.new(stage: stage, decision_class: decision.class.name)
        end

        def replace_helpers(input, helpers)
          return input.with(helpers: helpers) if input.respond_to?(:with)

          input.class.new(**input.to_h.merge(helpers: helpers))
        end

        def run_with_timeout(stage, timeout_s, &block)
          Timeout.timeout(timeout_s, Errors::StageTimeout.new(stage: stage, timeout_s: timeout_s), &block)
        end

        def enforce_output_limit!(stage, decision, max_output_bytes)
          serialized =
            if decision.respond_to?(:to_h)
              JSON.generate(decision.to_h)
            else
              decision.inspect.to_s
            end

          return decision if serialized.bytesize <= max_output_bytes

          raise Errors::OutputLimitExceeded.new(
            stage: stage,
            max_output_bytes: max_output_bytes,
            actual_output_bytes: serialized.bytesize,
          )
        rescue JSON::GeneratorError
          decision
        end

        def fallback_result(stage, failure_reason, error_class)
          Result.new(
            decision: fallback_decision_for(stage),
            fallback: true,
            failure_reason: failure_reason,
            error_class: error_class,
          )
        end

        def fallback_decision_for(_stage)
          Decisions::Pass.new
        end
    end
  end
end
