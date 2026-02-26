# frozen_string_literal: true

require "test_helper"

class ConversationChannelTest < ActionCable::Channel::TestCase
  tests ConversationChannel

  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    User.create!(identity: identity, role: :owner)

    stub_connection current_identity_id: identity.id

    identity
  end

  test "rejects subscription when unauthenticated" do
    conversation = Conversation.create!(title: "Chat", metadata: { "agent" => { "agent_profile" => "coding" } })

    subscribe conversation_id: conversation.id
    assert subscription.rejected?
  end

  test "poll transmits new node events for the current leaf node" do
    sign_in_owner!

    conversation = Conversation.create!(title: "Chat", metadata: { "agent" => { "agent_profile" => "coding" } })
    graph = conversation.dag_graph

    user = nil
    agent = nil

    graph.mutate! do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )

      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    subscribe conversation_id: conversation.id
    assert subscription.confirmed?

    stream = DAG::NodeEventStream.new(node: agent)
    stream.output_delta!("Hel")
    stream.output_delta!("lo")

    perform :poll

    assert transmissions.any?, "expected transmissions after polling"
    payload = transmissions.last

    assert_equal "node_events", payload.fetch("type")
    assert_equal agent.id, payload.fetch("node_id")
    assert_equal %w[Hel lo], payload.fetch("events").map { |e| e.fetch("text") }
  end

  test "poll includes preview text for output_compacted events" do
    sign_in_owner!

    conversation = Conversation.create!(title: "Chat", metadata: { "agent" => { "agent_profile" => "coding" } })
    graph = conversation.dag_graph

    user = nil
    agent = nil

    graph.mutate! do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )

      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    subscribe conversation_id: conversation.id
    assert subscription.confirmed?

    # Simulate the retention path where deltas are compacted and only a compacted
    # marker event remains, while the node's output_preview has the text.
    DAG::NodeBody.where(id: agent.body_id).update_all(
      output_preview: { "content" => "Compacted: Hello" },
      updated_at: Time.current,
    )

    DAG::NodeEvent.create!(
      graph: graph,
      node: agent,
      kind: DAG::NodeEvent::OUTPUT_COMPACTED,
      text: "",
      payload: { "source_kind" => DAG::NodeEvent::OUTPUT_DELTA },
    )

    perform :poll

    assert transmissions.any?, "expected transmissions after polling"
    payload = transmissions.last

    assert_equal "node_events", payload.fetch("type")
    assert_equal agent.id, payload.fetch("node_id")

    compacted = payload.fetch("events").find { |e| e.fetch("kind") == "output_compacted" }
    assert compacted, "expected an output_compacted event"
    assert_equal "Compacted: Hello", compacted.fetch("text")
  end
end

