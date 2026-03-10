module Cybros
  module ContextBudget
    class DefaultPolicy
      ACTIONS = {
        "normal" => "none",
        "soft_limit_reached" => "advise_compact",
        "near_hard_cap" => "enqueue_compact",
        "forced_fit" => "enqueue_compact",
      }.freeze

      def self.action_for(budget_state:)
        ACTIONS.fetch(budget_state.to_s, "none")
      end
    end
  end
end
