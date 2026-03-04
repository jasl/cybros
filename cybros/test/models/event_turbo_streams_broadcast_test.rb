require "test_helper"

class EventTurboStreamsBroadcastTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ActionCable::TestHelper

  teardown do
    ConversationRun.delete_all
    Event.delete_all
    Topic.delete_all
    Conversation.delete_all
    Session.delete_all
    User.delete_all
    Identity.delete_all

    DAG::NodeEvent.delete_all
    DAG::Edge.delete_all
    DAG::Node.delete_all
    DAG::NodeBody.delete_all
    DAG::Graph.delete_all
  end

  test "terminal node_state_changed broadcasts turbo replace for agent message" do
    user = create_user!
    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    stream_name = Turbo::StreamsChannel.send(:stream_name_from, [conversation, :messages])
    assert stream_name.present?

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
        )
    end

    DAG::NodeBody.where(id: agent.body_id).update_all(
      output_preview: { "content" => "**Done**" },
      updated_at: Time.current,
    )

    # In production this event is emitted after the node state has already been persisted.
    agent.update!(state: DAG::Node::FINISHED)

    assert_broadcasts(stream_name, 1) do
      Event.create!(
        conversation: conversation,
        subject: agent,
        event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
        particulars: { "from" => DAG::Node::RUNNING, "to" => DAG::Node::FINISHED },
      )
    end

    raw = broadcasts(stream_name).last
    assert raw.present?

    # Turbo stream payload is JSON-encoded by ActionCable helpers (escaped `<`).
    html = JSON.parse(raw)
    assert_includes html, %(<turbo-stream action="replace" target="message_#{agent.id}")
    assert_includes html, %(data-controller="markdown")
    assert_includes html, "**Done**"
  end
end
