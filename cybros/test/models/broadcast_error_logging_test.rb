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
    result = conversation.append_user_message!(content: "Hi")
    node = result.fetch(:agent_node)
    node.update!(state: "running")

    calls = []
    original_warn = Cybros::RateLimitedLog.method(:warn)

    Cybros::RateLimitedLog.singleton_class.send(:define_method, :warn) do |key, **kwargs|
      calls << { key: key, kwargs: kwargs }
      nil
    end

    with_singleton_override(ConversationChannel, :broadcast_node_event, ->(_conversation, _node_event) { raise "boom" }) do
      DAG::NodeEvent.create!(
        graph_id: node.graph_id,
        node_id: node.id,
        turn_id: node.turn_id,
        body_id: node.body_id,
        kind: "output_delta",
        text: "x",
        payload: {},
      )
    end

    assert calls.any? { |c| c.fetch(:key).to_s == "dag.node_event.broadcast_to_conversation" }
  ensure
    Cybros::RateLimitedLog.singleton_class.send(:define_method, :warn, original_warn)
  end

  test "Event broadcast failure is logged (rate limited)" do
    conversation = create_conversation!

    result = conversation.append_user_message!(content: "Hi")
    node = result.fetch(:agent_node)

    calls = []
    original_warn = Cybros::RateLimitedLog.method(:warn)

    Cybros::RateLimitedLog.singleton_class.send(:define_method, :warn) do |key, **kwargs|
      calls << { key: key, kwargs: kwargs }
      nil
    end

    with_singleton_override(ConversationChannel, :broadcast_to, ->(_conversation, _payload) { raise "boom" }) do
      Event.create!(
        conversation: conversation,
        event_type: "node_state_changed",
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
    result = conversation.append_user_message!(content: "Hi")
    node = result.fetch(:agent_node)
    node.update!(state: "running")

    node_event =
      DAG::NodeEvent.create!(
        graph_id: node.graph_id,
        node_id: node.id,
        turn_id: node.turn_id,
        body_id: node.body_id,
        kind: "output_delta",
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
