module AgentCore
  module Resources
    module Tools
      module Policy
        class Profiled < Base
          def initialize(allowed:, delegate:, tool_groups: nil, hidden: [], context_allowed: nil)
            @tool_groups = coerce_tool_groups(tool_groups)
            @allowed = expand_allowed(Array(allowed))
            @hidden = expand_allowed(Array(hidden))
            @context_allowed = context_allowed
            @delegate = delegate
          end

          def filter(tools:, context:)
            tools = Array(tools)
            visible = tools.select { |t| allowed_tool_definition?(t, context: context) }
            @delegate.filter(tools: visible, context: context)
          rescue StandardError
            []
          end

          def authorize(name:, arguments:, context:)
            if allowed_tool_name?(name, context: context)
              @delegate.authorize(name: name, arguments: arguments, context: context)
            else
              Decision.deny(reason: "tool_not_in_profile")
            end
          rescue StandardError
            Decision.deny(reason: "tool_not_in_profile")
          end

          private

            def coerce_tool_groups(value)
              case value
              when nil
                nil
              when ToolGroups
                value
              when Hash
                ToolGroups.new(groups: value)
              else
                nil
              end
            end

            def expand_allowed(patterns)
              groups = @tool_groups

              if groups
                groups.expand(patterns)
              else
                patterns
              end
            rescue StandardError
              patterns
            end

            def allowed_tool_definition?(tool_def, context:)
              name = tool_name_from_definition(tool_def)
              return false if name.to_s.strip.empty?

              allowed_tool_name?(name, context: context)
            rescue StandardError
              false
            end

            def allowed_tool_name?(name, context:)
              name = name.to_s
              context_allowed = expand_context_allowed(context)
              hidden = @hidden
              explicitly_allowed = context_allowed.any? { |pattern| pattern_match?(pattern, name) }

              return false if hidden.any? { |pattern| pattern_match?(pattern, name) } && !explicitly_allowed

              effective_allowed = @allowed + context_allowed
              return true if effective_allowed.any? { |p| p.to_s == "*" }

              effective_allowed.any? { |pattern| pattern_match?(pattern, name) }
            rescue StandardError
              false
            end

            def expand_context_allowed(context)
              value =
                case @context_allowed
                when Proc
                  @context_allowed.call(context)
                else
                  @context_allowed
                end

              expand_allowed(Array(value))
            rescue StandardError
              []
            end

            def pattern_match?(pattern, name)
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
