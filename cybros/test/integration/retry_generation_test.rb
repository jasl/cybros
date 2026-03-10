require "test_helper"

class RetryGenerationTest < ActionDispatch::IntegrationTest
  def agent_metadata(extra = {})
    { "llm" => { "model_ref" => Account.instance.llm_default_model_ref } }.deep_merge(extra)
  end

  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  test "retry endpoint creates a new agent node and queues a run" do
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
          state: DAG::Node::ERRORED,
          metadata: agent_metadata,
        )

      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    assert_difference -> { ConversationRun.count }, +1 do
      post retry_conversation_path(conversation), params: { node_id: agent.id }
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["node_id"].present?
    new_node = DAG::Node.find(body["node_id"])
    assert_equal Messages::AgentMessage.node_type_key, new_node.node_type
    assert_equal DAG::Node::PENDING, new_node.state
    assert_equal agent.turn_id, new_node.turn_id
    assert_equal agent.id, new_node.retry_of_id
    assert agent.reload.compressed_at.present?
  end

  test "retry endpoint rejects non-agent nodes" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    user = nil
    graph.mutate! do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )
    end

    post retry_conversation_path(conversation), params: { node_id: user.id }
    assert_response :unprocessable_entity
    assert_includes response.body, "not_an_agent_node"
  end

  test "retry endpoint rejects non-retryable states" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: agent_metadata,
        )
    end

    post retry_conversation_path(conversation), params: { node_id: agent.id }
    assert_response :unprocessable_entity
    assert_includes response.body, "not_retryable"
  end

  test "retry endpoint rejects when retry already queued" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    user = nil
    failed = nil
    queued_retry = nil

    graph.mutate! do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )
      failed =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::ERRORED,
          metadata: agent_metadata,
        )
      queued_retry =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: agent_metadata("retry_of_node_id" => failed.id),
        )

      m.create_edge(from_node: user, to_node: failed, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: queued_retry, edge_type: DAG::Edge::SEQUENCE)
    end

    post retry_conversation_path(conversation), params: { node_id: failed.id }
    assert_response :conflict
    assert_includes response.body, "retry_already_queued"
  end

  test "retry endpoint uses DAG retry replacement semantics for pending downstream nodes" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    user_node = nil
    failed = nil
    downstream = nil
    original_edge = nil

    graph.mutate! do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )
      failed =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::ERRORED,
          metadata: agent_metadata,
        )
      downstream =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user_node, to_node: failed, edge_type: DAG::Edge::SEQUENCE)
      original_edge = m.create_edge(from_node: failed, to_node: downstream, edge_type: DAG::Edge::SEQUENCE)
    end

    post retry_conversation_path(conversation), params: { node_id: failed.id }
    assert_response :success

    new_node = DAG::Node.find(JSON.parse(response.body).fetch("node_id"))
    assert_equal failed.id, new_node.retry_of_id
    assert failed.reload.compressed_at.present?

    assert graph.edges.active.exists?(
      from_node_id: user_node.id,
      to_node_id: new_node.id,
      edge_type: DAG::Edge::SEQUENCE,
    )

    assert graph.edges.active.exists?(
      from_node_id: new_node.id,
      to_node_id: downstream.id,
      edge_type: DAG::Edge::SEQUENCE,
    )

    assert original_edge.reload.compressed_at.present?
  end

  test "retry endpoint allows manual retry beyond historical depth 5" do
    user = sign_in_owner!

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    user_node = nil
    ancestors = []
    failed = nil

    graph.mutate! do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )

      previous = nil
      5.times do |index|
        node =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::STOPPED,
            lane_id: conversation.chat_lane.id,
            retry_of_id: previous&.id,
            metadata: agent_metadata("reason" => "attempt_#{index}"),
          )
        ancestors << node
        previous = node
      end

      failed =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::ERRORED,
          lane_id: conversation.chat_lane.id,
          retry_of_id: ancestors.last.id,
          metadata: agent_metadata("error" => "boom"),
        )

      m.create_edge(from_node: user_node, to_node: failed, edge_type: DAG::Edge::SEQUENCE)
    end

    assert_difference -> { ConversationRun.count }, +1 do
      post retry_conversation_path(conversation), params: { node_id: failed.id }
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["node_id"].present?
  end

  test "retry endpoint action override can discard interrupted output from future context" do
    user = sign_in_owner!

    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "input_policy" => {
            "interrupted_output_policy" => "keep_context",
          },
        },
      )
    graph = conversation.dag_graph

    user_node = nil
    stopped = nil

    graph.mutate! do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )
      stopped =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::STOPPED,
          body_output: { "content" => "partial" },
          metadata: agent_metadata("reason" => "interrupt_new_turn"),
        )

      m.create_edge(from_node: user_node, to_node: stopped, edge_type: DAG::Edge::SEQUENCE)
    end

    post retry_conversation_path(conversation),
         params: {
           node_id: stopped.id,
           interrupted_output_policy_override: "discard_context",
         }

    assert_response :success
    assert stopped.reload.context_excluded?
  end
end
