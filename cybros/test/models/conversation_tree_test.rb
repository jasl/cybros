require "test_helper"

class ConversationTreeTest < ActiveSupport::TestCase
  test "root conversation defaults to kind=root and root_conversation_id=self" do
    conversation = create_conversation!(title: "Root")

    assert_equal "root", conversation.kind
    assert_equal conversation.id, conversation.root_conversation_id
    assert_nil conversation.parent_conversation_id
    assert_nil conversation.forked_from_node_id
  end

  test "root conversation attaches to graph main lane via chat_lane" do
    conversation = create_conversation!(title: "Root")

    lane = conversation.chat_lane
    assert_equal DAG::Lane::MAIN, lane.role
    assert_equal conversation.id, lane.attachable_id
    assert_equal "Conversation", lane.attachable_type
  end
end
