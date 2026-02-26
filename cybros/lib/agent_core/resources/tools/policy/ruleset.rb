module AgentCore
  module Resources
    module Tools
      module Policy
        # Three-tier ruleset with fixed precedence: deny > confirm > allow.
        #
        # Rules are Hash specs compatible with PatternRules, except the decision
        # is implied by the list the rule appears in.
        #
        # filter delegates to the delegate policy to avoid hiding tools as a
        # side-effect of authorization defaults.
        class Ruleset < Base
          def initialize(deny: [], confirm: [], allow: [], delegate: ConfirmAll.new, tool_groups: nil)
            @delegate = delegate

            rules =
              build_rules(deny, outcome: :deny) +
                build_rules(confirm, outcome: :confirm) +
                build_rules(allow, outcome: :allow)

            @pattern_rules =
              PatternRules.new(
                rules: rules,
                delegate: delegate,
                tool_groups: tool_groups,
              )
          end

          def filter(tools:, context:)
            @delegate.filter(tools: tools, context: context)
          end

          def authorize(name:, arguments: {}, context:)
            @pattern_rules.authorize(name: name, arguments: arguments, context: context)
          end

          private

            def build_rules(list, outcome:)
              Array(list).map do |raw|
                unless raw.is_a?(Hash)
                  ValidationError.raise!(
                    "rule must be a Hash (got #{raw.class})",
                    code: "agent_core.tools.policy.ruleset.rule_must_be_a_hash_got",
                    details: { value_class: raw.class.name },
                  )
                end

                h = AgentCore::Utils.deep_symbolize_keys(raw)

                decision =
                  case outcome
                  when :deny
                    { outcome: "deny", reason: h[:reason] }
                  when :confirm
                    {
                      outcome: "confirm",
                      reason: h[:reason],
                      required: h[:required] == true,
                      deny_effect: h[:deny_effect],
                    }
                  when :allow
                    { outcome: "allow", reason: h[:reason] }
                  else
                    ValidationError.raise!(
                      "invalid outcome: #{outcome.inspect}",
                      code: "agent_core.tools.policy.ruleset.invalid_outcome",
                      details: { outcome: outcome.to_s },
                    )
                  end

                h.merge(decision: decision)
              end
            end
        end
      end
    end
  end
end
