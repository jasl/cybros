# frozen_string_literal: true

module AgentCore
  module Resources
    module Tools
      module Policy
        # Expands "group:<name>" references into tool name patterns.
        #
        # Tool groups are a convenience for profiles/rules that want to refer to
        # a set of tools without listing each name individually.
        #
        # Groups are intentionally a purely in-memory mapping; the app may
        # persist group refs (e.g., in "approved rules") and resolve them at
        # runtime.
        class ToolGroups
          GROUP_PREFIX = "group:"

          def initialize(groups: {})
            @groups = normalize_groups(groups)
          end

          attr_reader :groups

          def expand(patterns)
            expanded = []

            Array(patterns).each do |pattern|
              expand_one(pattern, expanded, stack: [])
            end

            expanded.uniq
          rescue StandardError
            Array(patterns).uniq
          end

          def group_names
            groups.keys.sort
          end

          def self.group_ref?(value)
            value.is_a?(String) && value.start_with?(GROUP_PREFIX)
          end

          private

            def normalize_groups(value)
              groups = value.is_a?(Hash) ? value : {}

              groups.each_with_object({}) do |(k, v), out|
                name = k.to_s.strip
                next if name.empty?

                patterns =
                  Array(v).filter_map do |p|
                    case p
                    when Regexp
                      p
                    else
                      s = p.to_s.strip
                      s.empty? ? nil : s
                    end
                  end

                out[name] = patterns.freeze
              end.freeze
            end

            def expand_one(pattern, expanded, stack:)
              if self.class.group_ref?(pattern)
                name = pattern.delete_prefix(GROUP_PREFIX).strip
                if name.empty?
                  expanded << pattern
                  return
                end

                if stack.include?(name) # avoid cycles
                  expanded << pattern
                  return
                end

                members = groups[name]
                if members.nil?
                  expanded << pattern
                  return
                end

                stack2 = stack + [name]
                members.each do |member|
                  expand_one(member, expanded, stack: stack2)
                end
              else
                expanded << pattern
              end
            end
        end
      end
    end
  end
end
