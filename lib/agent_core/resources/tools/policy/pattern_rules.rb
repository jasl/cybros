# frozen_string_literal: true

require "pathname"

module AgentCore
  module Resources
    module Tools
      module Policy
        # Rule-based tool authorization.
        #
        # PatternRules are intended for high-coverage, safety-oriented policies:
        # match by tool name + arguments (e.g., file paths, URLs) and decide
        # allow/confirm/deny.
        #
        # Rules can be provided as Ruby Hashes (future-friendly for persistence)
        # or as Rule objects.
        class PatternRules < Base
          Rule =
            Data.define(
              :tools,
              :argument_conditions,
              :decision,
              :id,
            ) do
              def initialize(tools:, argument_conditions:, decision:, id: nil)
                tool_patterns =
                  if tools.nil?
                    ["*"]
                  else
                    Array(tools)
                  end

                conditions = Array(argument_conditions)

                super(
                  tools: tool_patterns.freeze,
                  argument_conditions: conditions.freeze,
                  decision: decision,
                  id: id,
                )
              end

              def self.coerce(value, tool_groups:)
                return value if value.is_a?(Rule)

                unless value.is_a?(Hash)
                  ValidationError.raise!(
                    "rule must be a Hash (got #{value.class})",
                    code: "agent_core.tools.policy.pattern_rules.rule_must_be_a_hash_got",
                    details: { value_class: value.class.name },
                  )
                end

                h = AgentCore::Utils.deep_symbolize_keys(value)

                tools = ToolNameMatcher.expand(Array(h.fetch(:tools, h.fetch(:tool, ["*"]))), tool_groups: tool_groups)

                argument_conditions =
                  Array(h.fetch(:arguments, h.fetch(:when, []))).filter_map do |raw|
                    ArgumentCondition.coerce(raw)
                  end

                decision = DecisionSpec.coerce(h.fetch(:decision, nil))

                new(
                  tools: tools,
                  argument_conditions: argument_conditions,
                  decision: decision,
                  id: h[:id],
                )
              end

              def matches?(tool_name:, arguments:)
                return false unless ToolNameMatcher.match_any?(tools, tool_name)
                return true if argument_conditions.empty?

                argument_conditions.all? { |cond| cond.matches?(arguments) }
              rescue StandardError
                false
              end
            end

          ArgumentCondition =
            Data.define(
              :keys,
              :path,
              :match,
              :normalize,
            ) do
              MATCH_KEYS = %i[equals prefix glob regexp present absent].freeze
              NORMALIZERS = %i[none path command].freeze

              def initialize(keys: nil, path: nil, match:, normalize: :none)
                keys = Array(keys).map { |k| k.to_s.strip }.reject(&:empty?)
                path = Array(path).map { |k| k.to_s.strip }.reject(&:empty?)

                if keys.empty? && path.empty?
                  ValidationError.raise!(
                    "argument condition requires keys or path",
                    code: "agent_core.tools.policy.pattern_rules.argument_condition_requires_keys_or_path",
                  )
                end

                match = match.is_a?(Hash) ? AgentCore::Utils.deep_symbolize_keys(match) : {}
                provided = match.keys & MATCH_KEYS
                if provided.empty?
                  ValidationError.raise!(
                    "argument condition requires one of: #{MATCH_KEYS.join(", ")}",
                    code: "agent_core.tools.policy.pattern_rules.argument_condition_requires_matcher",
                    details: { match_keys: match.keys.map(&:to_s).sort },
                  )
                elsif provided.length > 1
                  ValidationError.raise!(
                    "argument condition must specify only one matcher (got #{provided.join(", ")})",
                    code: "agent_core.tools.policy.pattern_rules.argument_condition_multiple_matchers_not_allowed",
                    details: { provided: provided.map(&:to_s).sort },
                  )
                end

                matcher_key = provided.first
                matcher_value = match.fetch(matcher_key)

                compiled =
                  case matcher_key
                  when :equals, :prefix
                    matcher_value.to_s
                  when :glob
                    GlobMatcher.new(matcher_value.to_s)
                  when :regexp
                    matcher_value.is_a?(Regexp) ? matcher_value : Regexp.new(matcher_value.to_s)
                  when :present, :absent
                    unless matcher_value == true
                      ValidationError.raise!(
                        "#{matcher_key} must be true",
                        code: "agent_core.tools.policy.pattern_rules.argument_condition_#{matcher_key}_must_be_true",
                        details: { value: matcher_value },
                      )
                    end
                    true
                  end

                normalize = normalize.to_s.strip.downcase.tr("-", "_").to_sym
                normalize = :none unless NORMALIZERS.include?(normalize)

                super(
                  keys: keys.freeze,
                  path: path.freeze,
                  match: { matcher_key => compiled }.freeze,
                  normalize: normalize,
                )
              rescue RegexpError => e
                ValidationError.raise!(
                  "invalid regexp in rule: #{e.message}",
                  code: "agent_core.tools.policy.pattern_rules.argument_condition_invalid_regexp",
                )
              end

              def self.coerce(value)
                return value if value.is_a?(ArgumentCondition)

                unless value.is_a?(Hash)
                  ValidationError.raise!(
                    "argument condition must be a Hash (got #{value.class})",
                    code: "agent_core.tools.policy.pattern_rules.argument_condition_must_be_a_hash_got",
                    details: { value_class: value.class.name },
                  )
                end

                h = AgentCore::Utils.deep_symbolize_keys(value)
                key = h[:key]
                keys = h[:keys]

                new(
                  keys: keys || (key ? [key] : nil),
                  path: h[:path],
                  match: h.fetch(:match, h),
                  normalize: h.fetch(:normalize, :none),
                )
              end

              def matches?(arguments)
                value = extract_value(arguments)

                key, matcher = match.first

                if key == :absent
                  return blank_value?(value)
                elsif key == :present
                  return !blank_value?(value)
                end

                return false if blank_value?(value)

                strings = normalize_strings(value)
                strings.any? { |str| match_string?(key, matcher, str) }
              rescue StandardError
                false
              end

              private

                def extract_value(arguments)
                  args = arguments.is_a?(Hash) ? arguments : {}

                  if path.any?
                    dig_value(args, path)
                  else
                    fetch_first(args, keys)
                  end
                end

                def dig_value(hash, segments)
                  cur = hash

                  segments.each do |segment|
                    return nil unless cur.is_a?(Hash)
                    return nil unless cur.key?(segment)

                    cur = cur[segment]
                  end

                  cur
                end

                def fetch_first(hash, keys)
                  keys.each do |k|
                    return hash[k] if hash.key?(k)
                  end

                  nil
                end

                def blank_value?(value)
                  case value
                  when nil
                    true
                  when String
                    value.strip.empty?
                  when Array
                    value.empty?
                  else
                    false
                  end
                end

                def normalize_strings(value)
                  list =
                    case value
                    when String
                      [value]
                    when Array
                      value.select { |v| v.is_a?(String) }
                    else
                      []
                    end

                  list
                    .map { |s| normalize_string(s) }
                    .reject { |s| s.strip.empty? }
                end

                def normalize_string(value)
                  case normalize
                  when :path
                    Pathname.new(value.tr("\\", "/")).cleanpath.to_s
                  when :command
                    value.lstrip
                  else
                    value
                  end
                end

                def match_string?(key, matcher, value)
                  case key
                  when :equals
                    value == matcher
                  when :prefix
                    value.start_with?(matcher)
                  when :glob
                    matcher.match?(value)
                  when :regexp
                    matcher.match?(value)
                  else
                    false
                  end
                end
            end

          class GlobMatcher
            def initialize(pattern)
              @pattern = pattern.to_s
              @regex = compile(@pattern)
            end

            def match?(value)
              @regex.match?(value.to_s)
            rescue StandardError
              false
            end

            private

              def compile(pattern)
                glob = pattern.to_s.tr("\\", "/")

                out = +"\\A"
                i = 0

                while i < glob.length
                  ch = glob.getbyte(i)

                  if ch == 42 # *
                    if glob.getbyte(i + 1) == 42 # **
                      i += 2
                      out << ".*"
                    else
                      i += 1
                      out << "[^/]*"
                    end
                  elsif ch == 63 # ?
                    i += 1
                    out << "[^/]"
                  elsif ch == 91 # [
                    j = i + 1
                    j += 1 while j < glob.length && glob.getbyte(j) != 93
                    if j < glob.length
                      cls = glob.byteslice(i, j - i + 1)
                      out << cls
                      i = j + 1
                    else
                      out << "\\["
                      i += 1
                    end
                  else
                    out << Regexp.escape(glob.byteslice(i, 1))
                    i += 1
                  end
                end

                out << "\\z"
                Regexp.new(out)
              end
          end

          module ToolNameMatcher
            module_function

            def expand(patterns, tool_groups:)
              patterns = Array(patterns)

              if tool_groups
                tool_groups.expand(patterns)
              else
                patterns
              end
            rescue StandardError
              patterns
            end

            def match_any?(patterns, tool_name)
              name = tool_name.to_s
              return false if name.strip.empty?

              Array(patterns).any? { |p| match_one?(p, name) }
            rescue StandardError
              false
            end

            def match_one?(pattern, name)
              case pattern
              when Regexp
                pattern.match?(name)
              else
                str = pattern.to_s
                return true if str == "*"

                if str.end_with?("*") && str.count("*") == 1
                  prefix = str.delete_suffix("*")
                  name.start_with?(prefix)
                elsif str.include?("*")
                  false
                else
                  name == str
                end
              end
            rescue StandardError
              false
            end
            private_class_method :match_one?
          end

          module DecisionSpec
            module_function

            def coerce(value)
              return value if value.is_a?(Decision)

              unless value.is_a?(Hash)
                ValidationError.raise!(
                  "decision must be a Hash",
                  code: "agent_core.tools.policy.pattern_rules.decision_must_be_a_hash",
                  details: { value_class: value.class.name },
                )
              end

              h = AgentCore::Utils.deep_symbolize_keys(value)
              outcome = h.fetch(:outcome, nil).to_s.strip.downcase.tr("-", "_").to_sym

              reason = h[:reason].to_s
              reason = nil if reason.strip.empty?

              case outcome
              when :allow
                Decision.allow(reason: reason)
              when :deny
                Decision.deny(reason: reason || "denied_by_rule")
              when :confirm
                Decision.confirm(
                  reason: reason || "confirmation_required_by_rule",
                  required: h[:required] == true,
                  deny_effect: h[:deny_effect],
                )
              else
                ValidationError.raise!(
                  "invalid decision outcome: #{outcome.inspect}",
                  code: "agent_core.tools.policy.pattern_rules.decision_invalid_outcome",
                  details: { outcome: outcome.to_s, allowed: Decision::OUTCOMES.map(&:to_s).sort },
                )
              end
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
