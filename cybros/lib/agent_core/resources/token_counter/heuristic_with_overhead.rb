module AgentCore
  module Resources
    module TokenCounter
      class HeuristicWithOverhead < Heuristic
        attr_reader :per_message_overhead

        def initialize(per_message_overhead:, **heuristic_kwargs)
          overhead = Integer(per_message_overhead, exception: false)
          ValidationError.raise!(
            "per_message_overhead must be a non-negative Integer",
            code: "agent_core.resources.token_counter.heuristic_with_overhead.per_message_overhead_must_be_a_non_negative_integer",
            details: { per_message_overhead: per_message_overhead },
          ) unless overhead && overhead >= 0

          @per_message_overhead = overhead
          super(**heuristic_kwargs)
        end

        def count_messages(messages)
          super(messages, per_message_overhead: per_message_overhead)
        end
      end
    end
  end
end
