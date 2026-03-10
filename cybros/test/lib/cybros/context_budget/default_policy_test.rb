require "test_helper"

class DefaultPolicyTest < ActiveSupport::TestCase
  test "maps bundled budget states to actions" do
    assert_equal "none", Cybros::ContextBudget::DefaultPolicy.action_for(budget_state: "normal")
    assert_equal "advise_compact", Cybros::ContextBudget::DefaultPolicy.action_for(budget_state: "soft_limit_reached")
    assert_equal "enqueue_compact", Cybros::ContextBudget::DefaultPolicy.action_for(budget_state: "near_hard_cap")
    assert_equal "enqueue_compact", Cybros::ContextBudget::DefaultPolicy.action_for(budget_state: "forced_fit")
  end
end
