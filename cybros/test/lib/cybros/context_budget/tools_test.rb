require "test_helper"

class Cybros::ContextBudget::ToolsTest < ActiveSupport::TestCase
  test "context budget estimated token offsets ignore malformed metadata shapes" do
    task_node = Struct.new(:metadata).new({ "context_budget" => { "estimated_tokens" => "nope" } })
    plan = Struct.new(:estimated_tokens).new(100)

    offset =
      Cybros::ContextBudget::Tools.send(
        :context_budget_estimated_tokens_offset_for,
        task_node: task_node,
        plan: plan,
      )

    assert_equal 0, offset
  end

  test "runtime surface resolution returns nil when runtime does not expose runtime surface hooks" do
    assert_nil Cybros::ContextBudget::Tools.send(:runtime_surface_resolution_for, Object.new)
  end
end
