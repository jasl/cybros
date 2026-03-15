require_relative "tools/memory_tools"
require_relative "tools/web_tools"
require_relative "tools/workspace_tools"

module Cybros
  module Agents
    module Claw
      class ToolExecutor
        def initialize(application:)
          @application = application
        end

        def call(params:)
          normalized_params = params.is_a?(Hash) ? Manifest.deep_stringify(params) : {}
          { "result" => execute(normalized_params) }
        rescue StandardError => e
          {
            "result" => error_result("tool.execute failed: #{e.class}: #{e.message}")
          }
        end

        private

        def execute(params)
          implementation_ref = params.fetch("implementation_ref", "").to_s
          logical_tool_name = params.fetch("logical_tool_name", "").to_s
          tool_call_id = params.fetch("tool_call_id", "").to_s

          unless implementation_ref.start_with?("claw:")
            return error_result("Unsupported claw implementation_ref: #{implementation_ref}")
          end

          if (memory_result = memory_tools(params).call(logical_tool_name: logical_tool_name, arguments: normalized_arguments(params), tool_call_id: tool_call_id))
            return memory_result
          end

          if (workspace_result = workspace_tools(params).call(logical_tool_name: logical_tool_name, arguments: normalized_arguments(params)))
            return workspace_result
          end

          if (web_result = web_tools.call(logical_tool_name: logical_tool_name, arguments: normalized_arguments(params)))
            return web_result
          end

          error_result("Claw tool #{logical_tool_name.presence || implementation_ref.delete_prefix("claw:")} is not implemented yet")
        end

        def workspace_tools(params)
          @workspace_tools_by_root ||= {}
          workspace_root = workspace_root_from(params)
          return NullWorkspaceTools.instance if workspace_root.nil?

          @workspace_tools_by_root[workspace_root] ||= Tools::WorkspaceTools.new(workspace_root: workspace_root)
        end

        def memory_tools(params)
          @memory_tools_by_bearer ||= {}
          callback_session = params["callback_session"]
          key = callback_session.is_a?(Hash) ? callback_session.fetch("bearer", "__missing__").to_s : "__missing__"
          @memory_tools_by_bearer[key] ||= Tools::MemoryTools.new(callback_session: callback_session)
        end

        def web_tools
          @web_tools ||= Tools::WebTools.new(provider: @application.web_provider)
        end

        def workspace_root_from(params)
          execution_workspace = params.dig("execution_context", "workspace", "logical_workspace_root_path").to_s.strip
          return execution_workspace unless execution_workspace.empty?

          session_workspace = params.dig("session_context", "workspace", "logical_workspace_root_path").to_s.strip
          return session_workspace unless session_workspace.empty?

          nil
        end

        def normalized_arguments(params)
          arguments = params["arguments"]
          arguments.is_a?(Hash) ? arguments : {}
        end

        def error_result(text)
          {
            "content" => [
              {
                "type" => "text",
                "text" => text.to_s,
              }
            ],
            "error" => true,
            "metadata" => {}
          }
        end

        class NullWorkspaceTools
          include Singleton

          def call(logical_tool_name:, arguments:)
            _ = logical_tool_name
            _ = arguments
            nil
          end
        end
      end
    end
  end
end
