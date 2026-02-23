# frozen_string_literal: true

require "json"

module AgentCore
  module Resources
    module Tools
      module Policy
        module Factory
          extend self

          SUPPORTED_VERSION = 1

          TOP_LEVEL_KEYS = %i[version default rules prefix_rules].freeze
          DEFAULT_KEYS = %i[outcome reason required deny_effect].freeze
          RULES_KEYS = %i[deny confirm allow].freeze

          RULE_ITEM_KEYS = %i[id tools tool arguments when reason required deny_effect].freeze
          PREFIX_RULE_ITEM_KEYS =
            %i[id tools tool argument_key argument_keys prefixes allowed_prefixes reason].freeze

          def build(value, tool_groups: nil)
            config = parse_config(value)
            return DenyAll.new if config.nil? || config.empty?

            h = AgentCore::Utils.deep_symbolize_keys(config)
            assert_no_unknown_keys!(h, allowed: TOP_LEVEL_KEYS, path: "config")

            version = coerce_version(h.fetch(:version, SUPPORTED_VERSION))
            unless version == SUPPORTED_VERSION
              ValidationError.raise!(
                "unsupported policy config version: #{version}",
                code: "agent_core.tools.policy.factory.unsupported_version",
                details: { version: version, supported: [SUPPORTED_VERSION] },
              )
            end

            base = build_default_policy(h[:default])

            policy =
              if h.key?(:prefix_rules)
                build_prefix_rules_policy(h[:prefix_rules], delegate: base, tool_groups: tool_groups)
              else
                base
              end

            if h.key?(:rules)
              policy = build_ruleset_policy(h[:rules], delegate: policy, tool_groups: tool_groups)
            end

            policy
          end

          private

            def parse_config(value)
              case value
              when nil
                nil
              when String
                parsed =
                  begin
                    JSON.parse(value)
                  rescue JSON::ParserError => e
                    ValidationError.raise!(
                      "invalid JSON policy config: #{e.message}",
                      code: "agent_core.tools.policy.factory.invalid_json",
                    )
                  end

                unless parsed.is_a?(Hash)
                  ValidationError.raise!(
                    "policy config must be a JSON object",
                    code: "agent_core.tools.policy.factory.json_must_be_an_object",
                    details: { value_class: parsed.class.name },
                  )
                end

                parsed
              when Hash
                value
              else
                ValidationError.raise!(
                  "policy config must be a Hash (got #{value.class})",
                  code: "agent_core.tools.policy.factory.config_must_be_a_hash_got",
                  details: { value_class: value.class.name },
                )
              end
            end

            def coerce_version(value)
              return SUPPORTED_VERSION if value.nil?
              return value if value.is_a?(Integer)

              int = Integer(value.to_s, exception: false)
              return int if int

              ValidationError.raise!(
                "version must be an Integer",
                code: "agent_core.tools.policy.factory.version_must_be_an_integer",
                details: { value: value.to_s },
              )
            end

            def build_default_policy(spec)
              if spec.nil?
                return ConfirmAll.new(reason: "needs_approval", required: false, deny_effect: nil)
              end

              unless spec.is_a?(Hash)
                ValidationError.raise!(
                  "default must be a Hash (got #{spec.class})",
                  code: "agent_core.tools.policy.factory.default_must_be_a_hash_got",
                  details: { value_class: spec.class.name },
                )
              end

              h = AgentCore::Utils.deep_symbolize_keys(spec)
              assert_no_unknown_keys!(h, allowed: DEFAULT_KEYS, path: "default")

              outcome = normalize_outcome(h.fetch(:outcome, "confirm"))

              reason = h[:reason].to_s.strip
              reason = nil if reason.empty?

              if outcome != :confirm && (h.key?(:required) || h.key?(:deny_effect))
                ValidationError.raise!(
                  "default.required/default.deny_effect are only valid for outcome=confirm",
                  code: "agent_core.tools.policy.factory.default_confirm_only_fields_not_allowed",
                  details: { outcome: outcome.to_s },
                )
              end

              case outcome
              when :allow
                AllowAll.new
              when :deny
                DenyAllVisible.new(reason: reason || "tool access denied")
              when :confirm
                required = coerce_boolean(h.fetch(:required, false), path: "default.required")
                deny_effect = h.fetch(:deny_effect, nil)

                ConfirmAll.new(
                  reason: reason || "needs_approval",
                  required: required,
                  deny_effect: deny_effect,
                )
              else
                ValidationError.raise!(
                  "invalid default outcome: #{outcome.inspect}",
                  code: "agent_core.tools.policy.factory.default_outcome_invalid",
                  details: { outcome: outcome.to_s, allowed: Decision::OUTCOMES.map(&:to_s).sort },
                )
              end
            end

            def build_prefix_rules_policy(spec, delegate:, tool_groups:)
              return delegate if spec.nil?

              unless spec.is_a?(Array)
                ValidationError.raise!(
                  "prefix_rules must be an Array (got #{spec.class})",
                  code: "agent_core.tools.policy.factory.prefix_rules_must_be_an_array_got",
                  details: { value_class: spec.class.name },
                )
              end

              rules =
                spec.map.with_index do |raw, idx|
                  unless raw.is_a?(Hash)
                    ValidationError.raise!(
                      "prefix_rules[#{idx}] must be a Hash (got #{raw.class})",
                      code: "agent_core.tools.policy.factory.prefix_rule_must_be_a_hash_got",
                      details: { index: idx, value_class: raw.class.name },
                    )
                  end

                  h = AgentCore::Utils.deep_symbolize_keys(raw)
                  assert_no_unknown_keys!(h, allowed: PREFIX_RULE_ITEM_KEYS, path: "prefix_rules[#{idx}]")

                  reason = h[:reason].to_s.strip
                  reason = nil if reason.empty?

                  h.merge(
                    decision: {
                      outcome: "allow",
                      reason: reason || "prefix_rule",
                    },
                  )
                end

              return delegate if rules.empty?

              PrefixRules.new(rules: rules, delegate: delegate, tool_groups: tool_groups)
            end

            def build_ruleset_policy(spec, delegate:, tool_groups:)
              return delegate if spec.nil?

              unless spec.is_a?(Hash)
                ValidationError.raise!(
                  "rules must be a Hash (got #{spec.class})",
                  code: "agent_core.tools.policy.factory.rules_must_be_a_hash_got",
                  details: { value_class: spec.class.name },
                )
              end

              h = AgentCore::Utils.deep_symbolize_keys(spec)
              assert_no_unknown_keys!(h, allowed: RULES_KEYS, path: "rules")

              deny = coerce_rule_list(h.fetch(:deny, []), outcome: :deny, path: "rules.deny")
              confirm = coerce_rule_list(h.fetch(:confirm, []), outcome: :confirm, path: "rules.confirm")
              allow = coerce_rule_list(h.fetch(:allow, []), outcome: :allow, path: "rules.allow")

              return delegate if deny.empty? && confirm.empty? && allow.empty?

              Ruleset.new(
                deny: deny,
                confirm: confirm,
                allow: allow,
                delegate: delegate,
                tool_groups: tool_groups,
              )
            end

            def coerce_rule_list(value, outcome:, path:)
              unless value.is_a?(Array)
                ValidationError.raise!(
                  "#{path} must be an Array (got #{value.class})",
                  code: "agent_core.tools.policy.factory.rule_list_must_be_an_array_got",
                  details: { path: path, value_class: value.class.name },
                )
              end

              value.map.with_index do |raw, idx|
                unless raw.is_a?(Hash)
                  ValidationError.raise!(
                    "#{path}[#{idx}] must be a Hash (got #{raw.class})",
                    code: "agent_core.tools.policy.factory.rule_must_be_a_hash_got",
                    details: { path: path, index: idx, value_class: raw.class.name },
                  )
                end

                h = AgentCore::Utils.deep_symbolize_keys(raw)
                assert_no_unknown_keys!(h, allowed: RULE_ITEM_KEYS, path: "#{path}[#{idx}]")

                if outcome != :confirm && (h.key?(:required) || h.key?(:deny_effect))
                  ValidationError.raise!(
                    "#{path}[#{idx}] required/deny_effect are only valid for confirm rules",
                    code: "agent_core.tools.policy.factory.rule_confirm_only_fields_not_allowed",
                    details: { path: path, index: idx, outcome: outcome.to_s },
                  )
                end

                h
              end
            end

            def normalize_outcome(value)
              value.to_s.strip.downcase.tr("-", "_").to_sym
            end

            def coerce_boolean(value, path:)
              return true if value == true
              return false if value == false

              ValidationError.raise!(
                "#{path} must be a boolean",
                code: "agent_core.tools.policy.factory.path_must_be_a_boolean",
                details: { path: path.to_s, value_class: value.class.name },
              )
            end

            def assert_no_unknown_keys!(hash, allowed:, path:)
              unknown = hash.keys - Array(allowed)
              return if unknown.empty?

              ValidationError.raise!(
                "#{path} has unknown keys: #{unknown.sort.join(", ")}",
                code: "agent_core.tools.policy.factory.unknown_keys",
                details: { path: path.to_s, unknown: unknown.map(&:to_s).sort, allowed: Array(allowed).map(&:to_s).sort },
              )
            end
        end
      end
    end
  end
end
