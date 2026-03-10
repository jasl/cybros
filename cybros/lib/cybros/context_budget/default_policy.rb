module Cybros
  module ContextBudget
    class DefaultPolicy
      ACTIONS = {
        "normal" => "none",
        "soft_limit_reached" => "advise_compact",
        "near_hard_cap" => "enqueue_compact",
        "forced_fit" => "enqueue_compact",
      }.freeze

      def self.action_for(budget_state:, compact_context_suppressed: false)
        return "none" if compact_context_suppressed

        ACTIONS.fetch(budget_state.to_s, "none")
      end
    end
  end
end
