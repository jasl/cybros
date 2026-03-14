require "test_helper"

class ConversationProgramSelectionTest < ActiveSupport::TestCase
  test "new conversations default to the bundled default agent" do
    assert defined?(Agent), "expected Agent to be the public conversation binding"
    assert_equal :agent, Conversation.reflect_on_association(:agent)&.name
    assert_nil Conversation.reflect_on_association(:agent_program)
    assert_nil Conversation.reflect_on_association(:default_execution_target)
  end
end
