# frozen_string_literal: true

module AgentCore
  module Resources
    module Tools
      module Policy
        # The result of a policy authorization check.
        class Decision
          OUTCOMES = %i[allow deny confirm].freeze

          attr_reader :outcome, :reason, :required, :deny_effect

          def initialize(outcome:, reason: nil, required: false, deny_effect: nil)
            unless OUTCOMES.include?(outcome)
              raise ArgumentError, "Invalid outcome: #{outcome}. Must be one of: #{OUTCOMES.join(", ")}"
            end
            @outcome = outcome
            @reason = reason
            @required = required == true
            @deny_effect = deny_effect
          end

          def allowed? = outcome == :allow
          def denied? = outcome == :deny
          def requires_confirmation? = outcome == :confirm

          def self.allow(reason: nil)
            new(outcome: :allow, reason: reason)
          end

          def self.deny(reason:)
            new(outcome: :deny, reason: reason)
          end

          def self.confirm(reason:, required: false, deny_effect: nil)
            new(outcome: :confirm, reason: reason, required: required, deny_effect: deny_effect)
          end
        end
      end
    end
  end
end
