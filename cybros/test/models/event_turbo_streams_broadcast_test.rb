require "test_helper"

class EventTurboStreamsBroadcastTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ActionCable::TestHelper

  teardown do
    ActiveRecord::Base.lease_connection.disable_referential_integrity do
      RunDraft.delete_all
      ConversationRun.delete_all
      Event.delete_all
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
  end

  test "terminal node_state_changed broadcasts turbo replaces for the agent message and transcript list" do
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

    existing_count = broadcasts(stream_name).size

    assert_broadcasts(stream_name, 2) do
      Event.create!(
        conversation: conversation,
        subject: agent,
        event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
        particulars: { "from" => DAG::Node::RUNNING, "to" => DAG::Node::FINISHED },
      )
    end

    payloads = broadcasts(stream_name).drop(existing_count).map { |raw| JSON.parse(raw) }
    message_update = payloads.find { |html| html.include?(%(target="message_#{agent.id}")) }
    list_id = ActionView::RecordIdentifier.dom_id(conversation, :messages_list)
    list_update = payloads.find { |html| html.include?(%(target="#{list_id}")) }

    assert message_update.present?
    assert list_update.present?

    assert_includes message_update, %(<turbo-stream action="replace" target="message_#{agent.id}")
    assert_includes message_update, %(data-controller="markdown")
    assert_includes message_update, "**Done**"
    assert_includes message_update, %(data-message-actions-action-policy-value=)
    assert_includes message_update, %(&quot;regenerate&quot;:{&quot;supported&quot;:true,&quot;available&quot;:true,&quot;mode&quot;:&quot;in_place&quot;})
  end

  test "terminal node_state_changed also broadcasts a refreshed messages list when a queued turn becomes active" do
    user = create_user!
    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "running_input_policy" => "queue",
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    stream_name = Turbo::StreamsChannel.send(:stream_name_from, [conversation, :messages])
    assert stream_name.present?

    first = conversation.append_user_message!(content: "first request")
    first_agent = first.fetch(:agent_node)

    first_agent.mark_running!
    assert_equal DAG::Node::RUNNING, first_agent.reload.state

    conversation.append_user_message!(content: "queued follow up")

    DAG::NodeBody.where(id: first_agent.body_id).update_all(
      output_preview: { "content" => "done" },
      updated_at: Time.current,
    )
    first_agent.update!(state: DAG::Node::FINISHED)

    existing_count = broadcasts(stream_name).size

    assert_broadcasts(stream_name, 2) do
      Event.create!(
        conversation: conversation,
        subject: first_agent,
        event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
        particulars: { "from" => DAG::Node::RUNNING, "to" => DAG::Node::FINISHED },
      )
    end

    html_payloads = broadcasts(stream_name).drop(existing_count).map { |raw| JSON.parse(raw) }
    list_id = ActionView::RecordIdentifier.dom_id(conversation, :messages_list)
    list_update = html_payloads.find { |html| html.include?(%(target="#{list_id}")) }

    assert list_update.present?
    assert_includes list_update, "queued follow up"
  end

  test "node_state broadcast includes stable envelope fields (event_id + turn_id)" do
    user = create_user!
    conversation = create_conversation!(user: user, title: "Chat")
    result = conversation.append_user_message!(content: "Hi")
    agent = result.fetch(:agent_node)
    agent.update!(state: "running")
    agent.update!(state: "finished")

    broadcasting = ConversationChannel.broadcasting_for(conversation)

    event = nil
    assert_broadcasts(broadcasting, 1) do
      event =
        Event.create!(
          conversation: conversation,
          subject: agent,
          event_type: "node_state_changed",
          particulars: { "from" => "running", "to" => "finished" },
        )
    end

    payload = JSON.parse(broadcasts(broadcasting).last)
    assert_equal "node_state", payload.fetch("type")
    assert_equal conversation.id.to_s, payload.fetch("conversation_id")
    assert_equal agent.id.to_s, payload.fetch("node_id")
    assert_equal "running", payload.fetch("from")
    assert_equal "finished", payload.fetch("to")

    assert_equal event.id.to_s, payload.fetch("event_id").to_s
    assert_equal agent.turn_id.to_s, payload.fetch("turn_id").to_s
  end
end
