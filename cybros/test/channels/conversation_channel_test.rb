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

    user = User.create!(identity: identity, role: :owner)

    stub_connection current_identity_id: identity.id

    user
  end

  test "rejects subscription when unauthenticated" do
    conversation = create_conversation!(title: "Chat")

    subscribe conversation_id: conversation.id
    assert subscription.rejected?
  end

  test "rejects subscription to a conversation owned by another user" do
    user_a = sign_in_owner!
    user_b = create_user!
    convo_b = create_conversation!(user: user_b, title: "B")

    subscribe conversation_id: convo_b.id
    assert subscription.rejected?
  end

  test "broadcasts node events on create" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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
    broadcasting = ConversationChannel.broadcasting_for(conversation)
    assert_broadcasts(broadcasting, 1) do
      stream.output_delta!("Hel")
    end

    payload = JSON.parse(broadcasts(broadcasting).last)
    assert_equal "node_event", payload.fetch("type")
    assert_equal conversation.id.to_s, payload.fetch("conversation_id")
    assert_equal agent.id.to_s, payload.fetch("node_id")
    assert_equal "output_delta", payload.fetch("kind")
    assert_equal "Hel", payload.fetch("text")
  end

  test "broadcast includes preview text for output_compacted events" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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

    broadcasting = ConversationChannel.broadcasting_for(conversation)
    assert_broadcasts(broadcasting, 1) do
      DAG::NodeEvent.create!(
        graph: graph,
        node: agent,
        kind: DAG::NodeEvent::OUTPUT_COMPACTED,
        text: "",
        payload: { "source_kind" => DAG::NodeEvent::OUTPUT_DELTA },
      )
    end

    payload = JSON.parse(broadcasts(broadcasting).last)
    assert_equal "node_event", payload.fetch("type")
    assert_equal agent.id.to_s, payload.fetch("node_id")
    assert_equal "output_compacted", payload.fetch("kind")
    assert_equal "Compacted: Hello", payload.fetch("text")
  end

  test "subscribing with cursor replays missed events" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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

    first =
      DAG::NodeEvent.create!(
        graph: graph,
        node: agent,
        kind: DAG::NodeEvent::OUTPUT_DELTA,
        text: "A",
        payload: {},
      )

    DAG::NodeEvent.create!(
      graph: graph,
      node: agent,
      kind: DAG::NodeEvent::OUTPUT_DELTA,
      text: "B",
      payload: {},
    )

    transmissions.clear
    subscribe conversation_id: conversation.id, node_id: agent.id, cursor: first.id
    assert subscription.confirmed?

    assert transmissions.any?, "expected replay transmissions"
    payload = transmissions.last
    assert_equal "replay_batch", payload.fetch("type")
    events = payload.fetch("events")
    assert_equal 1, events.length
    assert_equal "node_event", events.last.fetch("type")
    assert_equal "B", events.last.fetch("text")
  end

  test "subscribing without cursor uses preview to avoid replay duplication" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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

    # If preview exists, the channel initializes cursor to the latest event id.
    DAG::NodeBody.where(id: agent.body_id).update_all(
      output_preview: { "content" => "Preview already has text" },
      updated_at: Time.current,
    )

    DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "A", payload: {})
    DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "B", payload: {})

    transmissions.clear
    subscribe conversation_id: conversation.id, node_id: agent.id
    assert subscription.confirmed?

    # Should not transmit a replay_batch because cursor was set to the latest event.
    assert transmissions.empty?, "expected no replay transmissions when preview content is present"
  end

  test "replay_batch includes preview text for output_compacted events when text is blank" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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

    DAG::NodeBody.where(id: agent.body_id).update_all(
      output_preview: { "content" => "Compacted preview" },
      updated_at: Time.current,
    )

    first = DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "A", payload: {})
    DAG::NodeEvent.create!(
      graph: graph,
      node: agent,
      kind: DAG::NodeEvent::OUTPUT_COMPACTED,
      text: "",
      payload: { "source_kind" => DAG::NodeEvent::OUTPUT_DELTA },
    )

    transmissions.clear
    subscribe conversation_id: conversation.id, node_id: agent.id, cursor: first.id
    assert subscription.confirmed?

    assert transmissions.any?, "expected replay transmissions"
    payload = transmissions.last
    assert_equal "replay_batch", payload.fetch("type")
    events = payload.fetch("events")
    assert_equal 1, events.length
    assert_equal "output_compacted", events.last.fetch("kind")
    assert_equal "Compacted preview", events.last.fetch("text")
  end

  test "broadcasts node_state changes" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    subscribe conversation_id: conversation.id
    assert subscription.confirmed?

    broadcasting = ConversationChannel.broadcasting_for(conversation)
    assert_broadcasts(broadcasting, 1) do
      DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    end

    payload = JSON.parse(broadcasts(broadcasting).last)
    assert_equal "node_state", payload.fetch("type")
    assert_equal conversation.id.to_s, payload.fetch("conversation_id")
    assert_equal agent.id.to_s, payload.fetch("node_id")
    assert_equal DAG::Node::PENDING, payload.fetch("from")
    assert_equal DAG::Node::RUNNING, payload.fetch("to")
  end

  test "poll_fallback replays events after cursor" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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

    first = DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "A", payload: {})

    subscribe conversation_id: conversation.id, node_id: agent.id, cursor: first.id
    assert subscription.confirmed?

    transmissions.clear
    DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "B", payload: {})

    perform :poll_fallback

    assert transmissions.any?, "expected fallback poll transmissions"
    payload = transmissions.last
    assert_equal "replay_batch", payload.fetch("type")
    events = payload.fetch("events")
    assert_equal 1, events.length
    assert_equal "node_event", events.last.fetch("type")
    assert_equal "B", events.last.fetch("text")
  end

  test "replay_batch events are ordered by event_id and cursor prevents older replays" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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

    ids = 5.times.map do |i|
      DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "t#{i}", payload: {}).id.to_s
    end

    cursor = ids[1]

    transmissions.clear
    subscribe conversation_id: conversation.id, node_id: agent.id, cursor: cursor
    assert subscription.confirmed?

    payload = transmissions.last
    assert_equal "replay_batch", payload.fetch("type")
    events = payload.fetch("events")
    assert_equal 3, events.length

    event_ids = events.map { |e| e.fetch("event_id") }
    assert_equal ids[2..], event_ids

    # After cursor advances, poll_fallback should replay only newly-created events.
    transmissions.clear
    DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "new", payload: {})
    perform :poll_fallback
    assert transmissions.any?, "expected replay transmissions for newly-created event"
    payload = transmissions.last
    assert_equal "replay_batch", payload.fetch("type")
    events = payload.fetch("events")
    assert_equal 1, events.length
    assert_equal "new", events.last.fetch("text")
  end

  test "poll_fallback batches replay in chunks of 200 and resumes on next poll" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
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

    first = DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "0", payload: {})

    subscribe conversation_id: conversation.id, node_id: agent.id, cursor: first.id
    assert subscription.confirmed?

    transmissions.clear
    249.times do |i|
      DAG::NodeEvent.create!(graph: graph, node: agent, kind: DAG::NodeEvent::OUTPUT_DELTA, text: (i + 1).to_s, payload: {})
    end

    transmissions.clear
    perform :poll_fallback
    assert transmissions.any?, "expected replay transmissions"

    payload = transmissions.last
    assert_equal "replay_batch", payload.fetch("type")
    events = payload.fetch("events")
    assert_equal 200, events.length

    # Second poll should send the remainder (49).
    transmissions.clear
    perform :poll_fallback
    payload = transmissions.last
    assert_equal "replay_batch", payload.fetch("type")
    events = payload.fetch("events")
    assert_equal 49, events.length
  end
end
