require "test_helper"
require "nokogiri"

class ConversationActionPolicyUiTest < ActionDispatch::IntegrationTest
  def sign_in_owner!
    email = "action-ui-#{SecureRandom.hex(4)}@example.com"
    identity =
      Identity.create!(
        email: email,
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    user = User.create!(identity: identity, role: :owner)

    post session_path, params: { email: email, password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  test "show renders action policy data for projected messages" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    agent = conversation.reload.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi v1")

    get conversation_path(conversation)
    assert_response :success

    assert_includes response.body, "data-message-actions-action-policy-value="
    assert_includes response.body, "&quot;regenerate&quot;:{&quot;supported&quot;:true,&quot;available&quot;:true,&quot;mode&quot;:&quot;in_place&quot;}"
  end

  test "show renders message-level retry button for errored agent messages" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    graph.mutate! do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hi",
          metadata: {},
        )
      agent_node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::ERRORED,
          lane_id: conversation.chat_lane.id,
          metadata: { "error" => "boom" },
        )
      m.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
    end

    get conversation_path(conversation)
    assert_response :success

    assert_includes response.body, "data-message-actions-target=\"retryButton\""
    assert_not_includes response.body, "data-message-actions-target=\"regenerateButton\""
  end

  test "show renders message-level start button for a tail pending assistant" do
    user = sign_in_owner!
    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
          },
        },
      )

    conversation.append_user_message!(content: "Hello")

    get conversation_path(conversation)
    assert_response :success

    assert_includes response.body, "data-message-actions-target=\"startButton\""
  end

  test "show renders swipe counter with disabled arrows for a single finished version" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    agent = conversation.reload.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi v1")

    get conversation_path(conversation)
    assert_response :success

    assert_select '[data-message-actions-target="swipeCount"]', text: "1 / 1"
    assert_select '[data-message-actions-target="swipeLeft"][disabled]', count: 1
    assert_select '[data-message-actions-target="swipeRight"][disabled]', count: 1
  end

  test "show keeps the latest assistant rerunnable when only a leaf-terminal authority task follows it" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    agent = conversation.reload.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi v1")

    conversation.root_graph.mutate! do |m|
      task =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: conversation.chat_lane.id,
          metadata: {
            "authored_metadata" => {
              "leaf_terminal" => true,
            },
          },
          body_input: {
            "name" => "cybros_generate_title",
          },
        )

      m.create_edge(from_node: agent, to_node: task, edge_type: DAG::Edge::SEQUENCE)
    end

    get conversation_path(conversation)
    assert_response :success

    assert_select '[data-message-actions-target="swipeCount"]', text: "1 / 1"
    assert_select '[data-message-actions-target="regenerateButton"]', count: 1
  end

  test "show renders swipe counter with directional availability for the active version" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    agent_v1 = conversation.reload.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent_v1.mark_running!
    agent_v1.mark_finished!(content: "Hi v1")

    post regenerate_conversation_path(conversation), params: { agent_node_id: agent_v1.id }
    agent_v2 = conversation.reload.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent_v2.mark_running!
    agent_v2.mark_finished!(content: "Hi v2")

    get conversation_path(conversation)
    assert_response :success

    assert_select '[data-message-actions-target="swipeCount"]', text: "2 / 2"
    assert_select '[data-message-actions-target="swipeLeft"]:not([disabled])', count: 1
    assert_select '[data-message-actions-target="swipeRight"][disabled]', count: 1
  end

  test "show hides regenerate for a non-tail assistant and leaves branch available" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    first_agent = conversation.reload.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    first_agent.mark_running!
    first_agent.mark_finished!(content: "Hi v1")

    post conversation_messages_path(conversation), params: { content: "Follow up" }
    second_agent = conversation.reload.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    second_agent.mark_running!
    second_agent.mark_finished!(content: "Hi v2")

    get conversation_path(conversation)
    assert_response :success

    first_wrapper = Nokogiri::HTML5.fragment(response.body).at_css(%([id="message_#{first_agent.id}"]))
    refute_nil first_wrapper

    refute_includes first_wrapper.to_html, 'data-message-actions-target="regenerateButton"'
    assert_includes first_wrapper.to_html, 'data-message-actions-target="branchButton"'
  end

  test "show renders edit for the latest user message and does not render branch" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    post conversation_messages_path(conversation), params: { content: "Hello" }
    user_node =
      conversation.reload.root_graph.nodes.active
        .where(lane_id: conversation.chat_lane.id, node_type: Messages::UserMessage.node_type_key)
        .order(:id)
        .last
    agent = conversation.chat_head_leaf(node_type: Messages::AgentMessage.node_type_key)
    agent.mark_running!
    agent.mark_finished!(content: "Hi")

    get conversation_path(conversation)
    assert_response :success

    user_wrapper = Nokogiri::HTML5.fragment(response.body).at_css(%([id="message_#{user_node.id}"]))
    refute_nil user_wrapper

    assert_includes user_wrapper.to_html, 'data-action="message-actions#edit"'
    refute_includes user_wrapper.to_html, 'data-message-actions-target="branchButton"'
  end

  test "show hides edit for the latest user message when the turn has attachments" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")
    append_result =
      conversation.append_user_message!(
        content: "",
        attachments: [
          Rack::Test::UploadedFile.new(
            Rails.root.join("test/fixtures/files/attachment-note.txt"),
            "text/plain",
          ),
        ],
      )
    user_node = append_result.fetch(:user_node)
    agent = append_result.fetch(:agent_node)
    agent.mark_running!
    agent.mark_finished!(content: "Hi")

    get conversation_path(conversation)
    assert_response :success

    user_wrapper = Nokogiri::HTML5.fragment(response.body).at_css(%([id="message_#{user_node.id}"]))
    refute_nil user_wrapper

    refute_includes user_wrapper.to_html, 'data-action="message-actions#edit"'
  end
end
