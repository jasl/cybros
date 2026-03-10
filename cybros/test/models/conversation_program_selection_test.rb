require "test_helper"

class ConversationProgramSelectionTest < ActiveSupport::TestCase
  test "execution-capable conversations require an agent program" do
    conversation = Conversation.new(title: "Conversation", user: create_user!)

    refute_predicate conversation, :valid?
    assert_includes conversation.errors[:agent_program], "must exist"
  end
end
