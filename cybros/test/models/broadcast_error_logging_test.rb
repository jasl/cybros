require "test_helper"

class BroadcastErrorLoggingTest < ActiveSupport::TestCase
  def with_singleton_override(klass, method_name, replacement)
    original = klass.method(method_name)
    klass.singleton_class.send(:define_method, method_name, replacement)
    yield
  ensure
    klass.singleton_class.send(:define_method, method_name, original)
  end

  test "DAG::NodeEvent broadcast failure is logged (rate limited)" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    node = nil
    graph.mutate! do |m|
      node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
        )
    end

    calls = []
    original_warn = Cybros::RateLimitedLog.method(:warn)

    Cybros::RateLimitedLog.singleton_class.send(:define_method, :warn) do |key, **kwargs|
      calls << { key: key, kwargs: kwargs }
      nil
    end

    with_singleton_override(ConversationChannel, :broadcast_node_event, ->(_conversation, _node_event) { raise "boom" }) do
      DAG::NodeEvent.create!(graph: graph, node: node, kind: DAG::NodeEvent::OUTPUT_DELTA, text: "x", payload: {})
    end

    assert calls.any? { |c| c.fetch(:key).to_s == "dag.node_event.broadcast_to_conversation" }
  ensure
    Cybros::RateLimitedLog.singleton_class.send(:define_method, :warn, original_warn)
  end

  test "Event broadcast failure is logged (rate limited)" do
    conversation = create_conversation!

    node = nil
    conversation.dag_graph.mutate! do |m|
      node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )
    end

    calls = []
    original_warn = Cybros::RateLimitedLog.method(:warn)

    Cybros::RateLimitedLog.singleton_class.send(:define_method, :warn) do |key, **kwargs|
      calls << { key: key, kwargs: kwargs }
      nil
    end

    with_singleton_override(ConversationChannel, :broadcast_to, ->(_conversation, _payload) { raise "boom" }) do
      Event.create!(
        conversation: conversation,
        event_type: DAG::GraphHooks::EventTypes::NODE_STATE_CHANGED,
        subject: node,
        particulars: { "from" => "pending", "to" => "running" },
      )
    end

    assert calls.any? { |c| c.fetch(:key).to_s == "event.broadcast_node_state_change" }
  ensure
    Cybros::RateLimitedLog.singleton_class.send(:define_method, :warn, original_warn)
  end

  test "ConversationChannel broadcast_node_event failure is logged (rate limited)" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    node = nil
    graph.mutate! do |m|
      node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          metadata: {},
        )
    end

    node_event =
      DAG::NodeEvent.create!(
        graph: graph,
        node: node,
        kind: DAG::NodeEvent::OUTPUT_DELTA,
        text: "x",
        payload: {},
      )

    calls = []
    original_warn = Cybros::RateLimitedLog.method(:warn)

    Cybros::RateLimitedLog.singleton_class.send(:define_method, :warn) do |key, **kwargs|
      calls << { key: key, kwargs: kwargs }
      nil
    end

    with_singleton_override(ConversationChannel, :broadcast_to, ->(_conversation, _payload) { raise "boom" }) do
      ConversationChannel.broadcast_node_event(conversation, node_event)
    end

    assert calls.any? { |c| c.fetch(:key).to_s == "conversation_channel.broadcast_node_event" }
  ensure
    Cybros::RateLimitedLog.singleton_class.send(:define_method, :warn, original_warn)
  end
end
