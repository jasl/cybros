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
        rescue SecurityError => e
          {
            "result" => error_result("tool.execute failed: #{e.class}: #{e.message}")
          }
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
          @workspace_tools_by_scope ||= {}
          workspace_config = workspace_config_from(params)
          return NullWorkspaceTools.instance if workspace_config.nil?

          cache_key = [workspace_config.fetch("root_path"), workspace_config.fetch("cwd")].join("\u0000")
          @workspace_tools_by_scope[cache_key] ||=
            Tools::WorkspaceTools.new(
              workspace_root: workspace_config.fetch("root_path"),
              cwd: workspace_config.fetch("cwd"),
            )
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

        def workspace_config_from(params)
          [params.dig("execution_context", "workspace"), params.dig("session_context", "workspace")].each do |workspace|
            next unless workspace.is_a?(Hash)

            root_path =
              workspace.fetch("root_path", "").to_s.strip.presence ||
                workspace.fetch("logical_workspace_root_path", "").to_s.strip.presence ||
                workspace.fetch("conversation_path", "").to_s.strip.presence ||
                workspace.fetch("cwd", "").to_s.strip.presence
            next if root_path.blank?

            cwd =
              workspace.fetch("cwd", "").to_s.strip.presence ||
                workspace.fetch("conversation_path", "").to_s.strip.presence ||
                root_path

            return { "root_path" => root_path, "cwd" => cwd }
          end

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
