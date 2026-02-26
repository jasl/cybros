module AgentCore
  module Resources
    module Tools
      module Policy
        # Prefix-based allow rules for shell/exec-style tools.
        #
        # Intended for persisting approvals like "allow any command starting with
        # `git status`" so the agent doesn't ask for confirmation repeatedly.
        #
        # This policy is conservative:
        # - It only matches against explicit string/array arguments.
        # - If it cannot extract a command string, it delegates.
        class PrefixRules < Base
          Rule =
            Data.define(
              :tools,
              :argument_keys,
              :prefixes,
              :decision,
              :id,
            ) do
              def initialize(tools:, argument_keys:, prefixes:, decision:, id: nil)
                tool_patterns =
                  if tools.nil?
                    ["*"]
                  else
                    Array(tools)
                  end

                keys = Array(argument_keys).map { |k| k.to_s.strip }.reject(&:empty?)
                ValidationError.raise!(
                  "prefix rule requires argument_keys",
                  code: "agent_core.tools.policy.prefix_rules.rule_requires_argument_keys",
                ) if keys.empty?

                prefixes = Array(prefixes).map { |p| p.to_s.strip }.reject(&:empty?)

                super(
                  tools: tool_patterns.freeze,
                  argument_keys: keys.freeze,
                  prefixes: prefixes.freeze,
                  decision: decision,
                  id: id,
                )
              end

              def self.coerce(value, tool_groups:)
                return value if value.is_a?(Rule)

                unless value.is_a?(Hash)
                  ValidationError.raise!(
                    "rule must be a Hash (got #{value.class})",
                    code: "agent_core.tools.policy.prefix_rules.rule_must_be_a_hash_got",
                    details: { value_class: value.class.name },
                  )
                end

                h = AgentCore::Utils.deep_symbolize_keys(value)

                tools = PatternRules::ToolNameMatcher.expand(Array(h.fetch(:tools, h.fetch(:tool, ["*"]))), tool_groups: tool_groups)

                keys =
                  if h[:argument_keys]
                    h[:argument_keys]
                  elsif h[:argument_key]
                    [h[:argument_key]]
                  else
                    ["command", "cmd"]
                  end

                prefixes = h.fetch(:prefixes, h.fetch(:allowed_prefixes, []))

                decision_hash = h.fetch(:decision, { outcome: "allow", reason: "prefix_rule" })

                new(
                  tools: tools,
                  argument_keys: keys,
                  prefixes: prefixes,
                  decision: PatternRules::DecisionSpec.coerce(decision_hash),
                  id: h[:id],
                )
              end

              def matches?(tool_name:, arguments:)
                return false unless PatternRules::ToolNameMatcher.match_any?(tools, tool_name)
                return false if prefixes.empty?

                raw = extract_command(arguments)
                return false if raw.nil?

                command = normalize_command(raw)
                return false if command.nil?

                if command.is_a?(String)
                  return false unless safe_command_string?(command)

                  prefixes.any? { |p| string_prefix_match?(command, p) }
                else
                  prefixes.any? { |p| argv_prefix_match?(command, p) }
                end
              rescue StandardError
                false
              end

              private

                def extract_command(arguments)
                  args = arguments.is_a?(Hash) ? arguments : {}
                  argument_keys.each do |key|
                    return args[key] if args.key?(key)
                  end

                  nil
                end

                def normalize_command(value)
                  case value
                  when String
                    out = value.lstrip
                    out.strip.empty? ? nil : out
                  when Array
                    argv = value.filter_map { |v| v.is_a?(String) ? v.strip : nil }.reject(&:empty?)
                    argv.empty? ? nil : argv
                  else
                    nil
                  end
                end

                def safe_command_string?(command)
                  return false if command.include?("\n") || command.include?("\r")
                  return false if command.include?("`")
                  return false if command.include?("$(")

                  !command.match?(/[;&|<>]/)
                end

                def string_prefix_match?(command, prefix)
                  p = prefix.to_s
                  return false if p.strip.empty?

                  return true if command == p
                  return false unless command.start_with?(p)

                  rest = command.byteslice(p.bytesize, command.bytesize - p.bytesize).to_s
                  rest.match?(/\A\s/)
                end

                def argv_prefix_match?(argv, prefix)
                  tokens = prefix.to_s.split(/\s+/).reject(&:empty?)
                  return false if tokens.empty?

                  argv.first(tokens.length) == tokens
                end
            end

          def initialize(rules:, delegate:, tool_groups: nil)
            @delegate = delegate
            @tool_groups = coerce_tool_groups(tool_groups)

            @rules =
              Array(rules).filter_map do |raw|
                Rule.coerce(raw, tool_groups: @tool_groups)
              end.freeze
          end

          def filter(tools:, context:)
            @delegate.filter(tools: tools, context: context)
          end

          def authorize(name:, arguments: {}, context:)
            tool_name = name.to_s
            args = AgentCore::Utils.deep_stringify_keys(arguments.is_a?(Hash) ? arguments : {})

            @rules.each do |rule|
              if rule.matches?(tool_name: tool_name, arguments: args)
                return rule.decision
              end
            end

            @delegate.authorize(name: name, arguments: arguments, context: context)
          rescue StandardError => e
            Decision.deny(reason: "policy_error=#{e.class}")
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
        end
      end
    end
  end
end
