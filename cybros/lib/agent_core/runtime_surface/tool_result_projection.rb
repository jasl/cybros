module AgentCore
  module RuntimeSurface
    class ToolResultProjection
      Projection =
        Data.define(
          :raw_result,
          :result_meta,
          :preview,
          :artifact_refs,
          :projected_result,
          :activity_preview,
          :action,
          :reason,
          :fallback,
          :failure_reason,
          :metadata,
        ) do
          def payload
            {
              "raw_result" => raw_result.to_h,
              "result_meta" => AgentCore::Utils.deep_stringify_keys(result_meta),
              "result_preview" => AgentCore::Utils.deep_stringify_keys(preview),
              "artifact_refs" => AgentCore::Utils.deep_stringify_keys(artifact_refs),
              "result" => projected_result.to_h,
              "activity_preview" => activity_preview.to_s,
              "projection" => {
                "action" => action.to_s,
                "reason" => reason.to_s,
                "fallback" => fallback,
                "failure_reason" => failure_reason&.to_s,
                "metadata" => AgentCore::Utils.deep_stringify_keys(metadata),
              }.compact,
            }
          end
        end

      def initialize(runtime:, execution_context:, tool_call:, context:)
        @runtime = runtime
        @execution_context = AgentCore::ExecutionContext.from(execution_context)
        @tool_call = AgentCore::Utils.deep_symbolize_keys(tool_call)
        @context = Array(context)
      end

      def call(raw_result:)
        raw_result = AgentCore::Resources::Tools::ToolResult.coerce(raw_result)
        result_meta = raw_result.projection_meta
        preview = raw_result.projection_preview
        artifact_refs = raw_result.artifact_refs

        runner_result =
          @runtime.runtime_surface_runner.run(
            surface: @runtime.runtime_surface,
            stage: :project_tool_result,
            input: project_tool_result_input(result_meta: result_meta, preview: preview, artifact_refs: artifact_refs),
            execution_context: @execution_context,
          )

        decision = runner_result.decision
        action = projection_action_for(decision)
        projected_result =
          case action
          when :replace
            coerce_projected_result(decision.projected_result, raw_result: raw_result)
          when :externalize
            externalized_result(raw_result: raw_result, reason: decision.reason)
          when :quarantine
            quarantined_result(raw_result: raw_result, reason: decision.reason)
          else
            raw_result.projected_copy
          end

        activity_preview = activity_preview_for(decision: decision, preview: preview, projected_result: projected_result)

        Projection.new(
          raw_result: raw_result,
          result_meta: result_meta,
          preview: preview,
          artifact_refs: artifact_refs,
          projected_result: projected_result,
          activity_preview: activity_preview,
          action: action,
          reason: decision.respond_to?(:reason) ? decision.reason : nil,
          fallback: runner_result.fallback?,
          failure_reason: runner_result.failure_reason,
          metadata: decision.respond_to?(:metadata) ? normalize_hash(decision.metadata) : {},
        ).tap do |projection|
          AgentCore::RuntimeSurface::AuditSerializer.publish_outcome(
            execution_context: @execution_context,
            stage: :project_tool_result,
            surface: @runtime.runtime_surface,
            outcome: {
              raw_result_ref: {
                error: raw_result.error?,
                content_block_count: raw_result.content.length,
                text_bytes: raw_result.text.to_s.bytesize,
                artifact_ref_count: artifact_refs.length,
              },
              projected_result: AgentCore::RuntimeSurface::AuditSerializer.output_summary(projected_result),
              projection_metadata: {
                action: action,
                reason: projection.reason,
                fallback: projection.fallback,
                failure_reason: projection.failure_reason,
                activity_preview_bytes: activity_preview.to_s.bytesize,
              },
            },
          )
        end
      end

      private

        def project_tool_result_input(result_meta:, preview:, artifact_refs:)
          AgentCore::RuntimeSurface::Inputs::ProjectToolResult.new(
            tool_call: AgentCore::Utils.deep_stringify_keys(@tool_call),
            result_meta: AgentCore::Utils.deep_stringify_keys(result_meta),
            preview: AgentCore::Utils.deep_stringify_keys(preview),
            artifact_refs: AgentCore::Utils.deep_stringify_keys(artifact_refs),
            context: @context,
            budget: {
              runtime_surface: AgentCore::Utils.deep_stringify_keys(@execution_context.attributes.fetch(:runtime_surface, {})),
              context_window_tokens: @runtime.context_window_tokens,
              reserved_output_tokens: @runtime.reserved_output_tokens,
            },
            helpers: {},
          )
        end

        def projection_action_for(decision)
          return :pass unless decision.is_a?(AgentCore::RuntimeSurface::Decisions::ToolResultProjection)

          action = decision.action.to_s.strip.downcase.to_sym
          return action if %i[pass replace externalize quarantine].include?(action)

          :pass
        rescue StandardError
          :pass
        end

        def coerce_projected_result(value, raw_result:)
          AgentCore::Resources::Tools::ToolResult.coerce(
            value || raw_result.projected_copy,
            error: raw_result.error?,
            metadata: raw_result.metadata,
          )
        rescue StandardError
          raw_result.projected_copy
        end

        def externalized_result(raw_result:, reason:)
          AgentCore::Resources::Tools::ToolResult.new(
            content: [{ type: :text, text: placeholder_text(prefix: "externalized", reason: reason) }],
            error: raw_result.error?,
            metadata: raw_result.metadata.merge("projection_action" => "externalize"),
          )
        end

        def quarantined_result(raw_result:, reason:)
          AgentCore::Resources::Tools::ToolResult.new(
            content: [{ type: :text, text: placeholder_text(prefix: "quarantined", reason: reason) }],
            error: raw_result.error?,
            metadata: raw_result.metadata.merge("projection_action" => "quarantine"),
          )
        end

        def placeholder_text(prefix:, reason:)
          reason_text = reason.to_s.strip
          suffix = reason_text.empty? ? "" : ": #{reason_text}"
          "[tool output #{prefix}#{suffix}]"
        end

        def activity_preview_for(decision:, preview:, projected_result:)
          metadata = decision.respond_to?(:metadata) ? normalize_hash(decision.metadata) : {}
          custom = metadata["activity_preview"].to_s
          return custom unless custom.empty?

          preview.fetch("text", projected_result.text.to_s).to_s
        rescue StandardError
          projected_result.text.to_s
        end

        def normalize_hash(value)
          value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
        end
    end
  end
end
