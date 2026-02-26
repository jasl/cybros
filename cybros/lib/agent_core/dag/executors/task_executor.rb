require "json"

module AgentCore
  module DAG
    module Executors
      class TaskExecutor
        DEFAULT_MAX_RESULT_BYTES = AgentCore::Utils::DEFAULT_MAX_TOOL_OUTPUT_BYTES

        def execute(node:, context:, stream:)
          _ = context
          _ = stream

          runtime = AgentCore::DAG.runtime_for(node: node)
          execution_context = ExecutionContextBuilder.build(node: node, runtime: runtime)

          tool_name, arguments = tool_call_from_input(node)

          result =
            execution_context.instrumenter.instrument(
              "agent_core.tool.execute",
              run_id: execution_context.run_id,
              tool: tool_name,
              provider: runtime_name(runtime),
            ) do
              runtime.tools_registry.execute(
                name: tool_name,
                arguments: arguments,
                context: execution_context,
                tool_error_mode: runtime.tool_error_mode
              )
            end

          result = truncate_result(result)

          ::DAG::ExecutionResult.finished(
            content: result.to_h,
            metadata: {
              "tool" => { "name" => tool_name },
              "agent" => AgentCore::Utils.deep_stringify_keys(execution_context.attributes.fetch(:agent, {})),
            },
          )
        rescue AgentCore::ToolNotFoundError => e
          ::DAG::ExecutionResult.errored(error: "ToolNotFoundError: #{e.message}")
        rescue StandardError => e
          ::DAG::ExecutionResult.errored(error: "#{e.class}: #{e.message}")
        end

        private

          def tool_call_from_input(node)
            input = node.body_input.is_a?(Hash) ? node.body_input : {}
            tool_name = input.fetch("name", "").to_s
            tool_name = input.fetch("requested_name", "").to_s if tool_name.strip.empty?

            ValidationError.raise!(
              "task.name is required",
              code: "agent_core.dag.task_executor.task_name_is_required",
            ) if tool_name.strip.empty?

            args = input.fetch("arguments", {})
            args = {} unless args.is_a?(Hash)
            [tool_name, AgentCore::Utils.deep_stringify_keys(args)]
          end

          def truncate_result(result)
            max_bytes = DEFAULT_MAX_RESULT_BYTES

            json =
              begin
                JSON.generate(result.to_h)
              rescue StandardError
                ""
              end

            return result if json.bytesize <= max_bytes

            truncated = AgentCore::Utils.truncate_utf8_bytes(json, max_bytes: max_bytes)

            AgentCore::Resources::Tools::ToolResult.new(
              content: [{ type: :text, text: truncated }],
              error: result.error?,
              metadata: result.metadata.merge(truncated: true),
            )
          rescue StandardError
            result
          end

          def runtime_name(runtime)
            if runtime.provider.respond_to?(:name)
              runtime.provider.name.to_s
            else
              runtime.provider.class.name
            end
          rescue StandardError
            "unknown"
          end
      end
    end
  end
end
