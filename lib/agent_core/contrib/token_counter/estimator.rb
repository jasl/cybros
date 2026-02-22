# frozen_string_literal: true

module AgentCore
  module Contrib
    module TokenCounter
      class Estimator < AgentCore::Resources::TokenCounter::Base
        attr_reader :token_estimator, :model_hint, :per_message_overhead

        def initialize(token_estimator:, model_hint: nil, per_message_overhead: 0)
          unless token_estimator.respond_to?(:estimate)
            ValidationError.raise!(
              "token_estimator must respond to #estimate",
              code: "agent_core.contrib.token_counter.estimator.token_estimator_must_respond_to_estimate",
              details: { token_estimator_class: token_estimator.class.name },
            )
          end

          overhead = Integer(per_message_overhead, exception: false)
          ValidationError.raise!(
            "per_message_overhead must be a non-negative Integer",
            code: "agent_core.contrib.token_counter.estimator.per_message_overhead_must_be_a_non_negative_integer",
            details: { per_message_overhead: per_message_overhead },
          ) unless overhead && overhead >= 0

          @token_estimator = token_estimator
          @model_hint = model_hint
          @per_message_overhead = overhead
        end

        def count_text(text)
          estimated = token_estimator.estimate(text.to_s, model_hint: model_hint)
          Integer(estimated, exception: false) || 0
        end

        def count_messages(messages)
          super(messages, per_message_overhead: per_message_overhead)
        end
      end
    end
  end
end
