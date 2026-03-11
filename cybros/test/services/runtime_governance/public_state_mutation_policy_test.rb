require "test_helper"

class RuntimeGovernance::PublicStateMutationPolicyTest < ActiveSupport::TestCase
  MUTATION_METHODS = %w[
    conversation.settings.update
    conversation.config.update
    lane.kv.set
    lane.kv.delete
    lane.prompt_buffer.put
    lane.prompt_buffer.delete
    lane.prompt_buffer.clear
  ].freeze

  test "conservative mode confirms all staged public-state mutation methods" do
    MUTATION_METHODS.each do |method_name|
      decision = RuntimeGovernance::PublicStateMutationPolicy.evaluate(method_name: method_name, permission_mode: "conservative")

      assert_equal "confirm", decision.fetch("decision")
      assert_equal true, decision.fetch("requires_confirmation")
      assert_equal "conservative", decision.fetch("permission_mode")
      assert_equal method_name, decision.fetch("method_name")
    end
  end

  test "default and full access modes allow all staged public-state mutation methods" do
    %w[default full_access].each do |permission_mode|
      MUTATION_METHODS.each do |method_name|
        decision = RuntimeGovernance::PublicStateMutationPolicy.evaluate(method_name: method_name, permission_mode: permission_mode)

        assert_equal "allow", decision.fetch("decision")
        assert_equal false, decision.fetch("requires_confirmation")
        assert_equal permission_mode, decision.fetch("permission_mode")
        assert_equal method_name, decision.fetch("method_name")
      end
    end
  end

  test "unknown mutation methods are denied explicitly" do
    decision = RuntimeGovernance::PublicStateMutationPolicy.evaluate(method_name: "conversation.settings.reset", permission_mode: "default")

    assert_equal "deny", decision.fetch("decision")
    assert_equal false, decision.fetch("requires_confirmation")
    assert_equal "public_state_mutation_method_unknown", decision.fetch("reason")
  end
end
