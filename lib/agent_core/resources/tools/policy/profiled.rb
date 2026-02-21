# frozen_string_literal: true

module AgentCore
  module Resources
    module Tools
      module Policy
        class Profiled < Base
          def initialize(allowed:, delegate:)
            @allowed = Array(allowed)
            @delegate = delegate
          end

          def filter(tools:, context:)
            tools = Array(tools)
            visible = tools.select { |t| allowed_tool_definition?(t) }
            @delegate.filter(tools: visible, context: context)
          rescue StandardError
            []
          end

          def authorize(name:, arguments:, context:)
            if allowed_tool_name?(name)
              @delegate.authorize(name: name, arguments: arguments, context: context)
            else
              Decision.deny(reason: "tool_not_in_profile")
            end
          rescue StandardError
            Decision.deny(reason: "tool_not_in_profile")
          end

          private

            def allowed_tool_definition?(tool_def)
              name = tool_name_from_definition(tool_def)
              return false if name.to_s.strip.empty?

              allowed_tool_name?(name)
            rescue StandardError
              false
            end

            def allowed_tool_name?(name)
              name = name.to_s
              return true if @allowed.any? { |p| p.to_s == "*" }

              @allowed.any? do |pattern|
                case pattern
                when Regexp
                  pattern.match?(name)
                else
                  str = pattern.to_s
                  if str.end_with?("*") && str.count("*") == 1
                    prefix = str.delete_suffix("*")
                    name.start_with?(prefix)
                  elsif str.include?("*")
                    false
                  else
                    name == str
                  end
                end
              end
            rescue StandardError
              false
            end

            def tool_name_from_definition(tool_def)
              return "" unless tool_def.is_a?(Hash)

              name = tool_def.fetch(:name, tool_def.fetch("name", ""))
              name = name.to_s
              return name unless name.strip.empty?

              type = tool_def.fetch(:type, tool_def.fetch("type", "")).to_s
              return "" unless type == "function"

              fn = tool_def.fetch(:function, tool_def.fetch("function", nil))
              return "" unless fn.is_a?(Hash)

              fn.fetch(:name, fn.fetch("name", "")).to_s
            rescue StandardError
              ""
            end
        end
      end
    end
  end
end
