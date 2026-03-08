module AgentCore
  module RuntimeSurface
    class AuditSerializer
      STRING_PREVIEW_BYTES = 200

      REDACTED_KEYS = %w[
        content
        body
        prompt
        messages
        tools
        arguments
        result
        raw
      ].freeze

      class << self
        def publish_stage(execution_context:, stage:, surface:, input:, result:)
          execution_context.instrumenter.publish(
            "agent_core.runtime_surface.audit",
            stage_payload(
              execution_context: execution_context,
              stage: stage,
              surface: surface,
              input: input,
              result: result,
            ),
          )
        rescue StandardError
          nil
        end

        def publish_outcome(execution_context:, stage:, surface:, outcome:)
          execution_context.instrumenter.publish(
            "agent_core.runtime_surface.audit",
            outcome_payload(
              execution_context: execution_context,
              stage: stage,
              surface: surface,
              outcome: outcome,
            ),
          )
        rescue StandardError
          nil
        end

        def stage_payload(execution_context:, stage:, surface:, input:, result:)
          {
            "kind" => "stage",
            "run_id" => execution_context.run_id,
            "stage" => stage.to_s,
            "runtime_surface_class" => surface.class.name,
            "surface_identity" => surface_identity(execution_context: execution_context, surface: surface),
            "input_snapshot" => input_snapshot(stage: stage, input: input),
            "decision" => decision_snapshot(stage: stage, decision: result.decision),
            "fallback" => result.fallback?,
            "failure_reason" => result.failure_reason&.to_s,
            "error_class" => result.error_class&.to_s,
          }.compact
        end

        def outcome_payload(execution_context:, stage:, surface:, outcome:)
          {
            "kind" => "outcome",
            "run_id" => execution_context.run_id,
            "stage" => stage.to_s,
            "runtime_surface_class" => surface.class.name,
            "surface_identity" => surface_identity(execution_context: execution_context, surface: surface),
            "merged_outcome" => sanitize_value(outcome),
          }
        end

        def output_summary(value)
          case value
          when AgentCore::Resources::Tools::ToolResult
            {
              "error" => value.error?,
              "content_block_count" => value.content.length,
              "text_bytes" => value.text.to_s.bytesize,
              "has_non_text_content" => value.has_non_text_content?,
            }
          when AgentCore::Message
            {
              "role" => value.role.to_s,
              "content_bytes" => value.text.to_s.bytesize,
              "tool_call_count" => Array(value.tool_calls).length,
            }
          when Hash
            hash = AgentCore::Utils.deep_stringify_keys(value)
            {
              "keys" => hash.keys.first(10),
              "content_bytes" => hash.fetch("content", hash.dig("message", "content")).to_s.bytesize,
              "tool_call_count" => Array(hash.fetch("tool_calls", hash.dig("message", "tool_calls"))).length,
              "has_directives" => hash.key?("directives"),
            }.compact
          else
            {
              "class" => value.class.name,
              "bytes" => value.to_s.bytesize,
            }
          end
        rescue StandardError
          { "class" => value.class.name }
        end

        private

          def surface_identity(execution_context:, surface:)
            identity = execution_context.respond_to?(:runtime_surface_identity) ? execution_context.runtime_surface_identity : {}
            identity = identity.merge("class" => surface.class.name)
            identity.compact
          rescue StandardError
            { "class" => surface.class.name }
          end

          def input_snapshot(stage:, input:)
            case stage.to_sym
            when :prepare_turn
              {
                "context_count" => Array(input.context).length,
                "prompt" => prompt_summary(input.prompt),
                "budget" => sanitize_value(input.budget),
                "capabilities" => sanitize_value(input.capabilities),
              }
            when :compact_context
              {
                "context_window_count" => Array(input.context_window).length,
                "budget" => sanitize_value(input.budget),
                "capabilities" => sanitize_value(input.capabilities),
              }
            when :review_tool_call
              {
                "tool_call" => sanitize_tool_call(input.tool_call),
                "context_count" => Array(input.context).length,
                "capabilities" => sanitize_value(input.capabilities),
                "risk_hints" => sanitize_value(input.risk_hints),
              }
            when :project_tool_result
              {
                "tool_call" => sanitize_tool_call(input.tool_call),
                "result_meta" => sanitize_value(input.result_meta),
                "preview" => preview_summary(input.preview),
                "artifact_ref_count" => Array(input.artifact_refs).length,
                "context_count" => Array(input.context).length,
                "budget" => sanitize_value(input.budget),
              }
            when :finalize_output
              {
                "draft_output" => output_summary(input.draft_output),
                "context_count" => Array(input.context).length,
                "budget" => sanitize_value(input.budget),
              }
            when :handle_error
              {
                "stage" => input.stage.to_s,
                "error" => sanitize_error(input.error),
                "context_count" => Array(input.context).length,
                "budget" => sanitize_value(input.budget),
              }
            else
              sanitize_value(input.respond_to?(:to_h) ? input.to_h : input)
            end
          rescue StandardError
            {}
          end

          def decision_snapshot(stage:, decision:)
            case decision
            when AgentCore::RuntimeSurface::Decisions::Pass
              { "type" => "pass" }
            when AgentCore::RuntimeSurface::Decisions::TurnRewrite
              { "type" => "turn_rewrite", "prompt" => prompt_summary(decision.prompt), "metadata_keys" => sanitize_metadata_keys(decision.metadata) }
            when AgentCore::RuntimeSurface::Decisions::ContextCompaction
              {
                "type" => "context_compaction",
                "kept_items_count" => Array(decision.kept_items).length,
                "summaries_count" => Array(decision.summaries).length,
                "externalized_items_count" => Array(decision.externalized_items).length,
                "metadata_keys" => sanitize_metadata_keys(decision.metadata),
              }
            when AgentCore::RuntimeSurface::Decisions::ToolCallSuggestion
              {
                "type" => "tool_call_suggestion",
                "action" => decision.action.to_s,
                "reason" => truncate_string(decision.reason),
                "patched_tool_call" => sanitize_tool_call(decision.patched_tool_call),
                "metadata_keys" => sanitize_metadata_keys(decision.metadata),
              }
            when AgentCore::RuntimeSurface::Decisions::ToolResultProjection
              {
                "type" => "tool_result_projection",
                "action" => decision.action.to_s,
                "reason" => truncate_string(decision.reason),
                "projected_result" => output_summary(AgentCore::Resources::Tools::ToolResult.coerce(decision.projected_result || {})),
                "metadata_keys" => sanitize_metadata_keys(decision.metadata),
              }
            when AgentCore::RuntimeSurface::Decisions::FinalOutput
              {
                "type" => "final_output",
                "output" => output_summary(decision.output),
                "metadata_keys" => sanitize_metadata_keys(decision.metadata),
              }
            when AgentCore::RuntimeSurface::Decisions::ErrorHandling
              {
                "type" => "error_handling",
                "action" => decision.action.to_s,
                "reason" => truncate_string(decision.reason),
                "output" => output_summary(decision.output),
                "metadata_keys" => sanitize_metadata_keys(decision.metadata),
              }
            else
              { "type" => decision.class.name }
            end
          rescue StandardError
            { "type" => stage.to_s }
          end

          def sanitize_tool_call(value)
            hash = value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
            return {} if hash.empty?

            {
              "id" => hash["id"].to_s.presence,
              "name" => hash.fetch("name", hash["resolved_name"]).to_s.presence,
              "resolved_name" => hash["resolved_name"].to_s.presence,
              "source" => hash["source"].to_s.presence,
              "name_resolution" => hash["name_resolution"].to_s.presence,
              "argument_keys" => extract_argument_keys(hash["arguments"]),
            }.compact
          rescue StandardError
            {}
          end

          def extract_argument_keys(value)
            return [] unless value.is_a?(Hash)

            value.keys.first(20).map(&:to_s)
          end

          def sanitize_error(value)
            hash = value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
            return sanitize_value(value) unless hash.is_a?(Hash)

            hash.slice("class", "status", "code", "validation_error", "recoverable")
          rescue StandardError
            {}
          end

          def preview_summary(value)
            hash = value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
            return {} unless hash.is_a?(Hash)

            {
              "text_bytes" => hash.fetch("text", "").to_s.bytesize,
              "error" => hash["error"],
              "truncated" => hash["truncated"],
              "redacted" => hash["redacted"],
              "non_text_content" => hash["non_text_content"],
            }.compact
          rescue StandardError
            {}
          end

          def prompt_summary(value)
            hash =
              case value
              when AgentCore::PromptBuilder::BuiltPrompt
                value.to_h
              when Hash
                value
              else
                {}
              end

            hash = AgentCore::Utils.deep_stringify_keys(hash)

            {
              "system_prompt_bytes" => hash.fetch("system_prompt", "").to_s.bytesize,
              "message_count" => Array(hash["messages"]).length,
              "tool_count" => Array(hash["tools"]).length,
              "option_keys" => hash.fetch("options", {}).is_a?(Hash) ? hash.fetch("options", {}).keys.first(10) : [],
            }
          rescue StandardError
            {}
          end

          def sanitize_metadata_keys(value)
            value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value).keys.first(20) : []
          rescue StandardError
            []
          end

          def sanitize_value(value)
            case value
            when nil, true, false, Integer, Float
              value
            when Symbol
              value.to_s
            when String
              truncate_string(value)
            when Array
              value.first(20).map { |item| sanitize_value(item) }
            when Hash
              AgentCore::Utils.deep_stringify_keys(value).each_with_object({}) do |(key, item), out|
                out[key] = REDACTED_KEYS.include?(key) ? "[redacted]" : sanitize_value(item)
              end
            else
              truncate_string(value.to_s)
            end
          rescue StandardError
            value.class.name
          end

          def truncate_string(value)
            AgentCore::Utils.truncate_utf8_bytes(value.to_s, max_bytes: STRING_PREVIEW_BYTES)
          end
      end
    end
  end
end
