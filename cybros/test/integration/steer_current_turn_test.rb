require "test_helper"

class SteerCurrentTurnTest < ActionDispatch::IntegrationTest
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

  test "steer_current_turn endpoint replaces the running turn in place" do
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
    graph = conversation.dag_graph

    created = conversation.append_user_message!(content: "draft request")
    original_user = created.fetch(:user_node)
    original_agent = created.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [original_agent.id], claimed.map(&:id)
    original_agent.body.merge_output!("content" => "partial answer")
    original_agent.body.save!

    assert_difference -> { ConversationRun.count }, +1 do
      post steer_current_turn_conversation_path(conversation),
           params: { content: "revised request" },
           as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["node_id"].present?

    new_agent = DAG::Node.find(body["node_id"])
    assert_equal original_user.turn_id, new_agent.turn_id
    assert original_user.reload.compressed_at.present?
    assert original_agent.reload.compressed_at.present?
  end

  test "steer_current_turn endpoint rejects when no turn is running" do
    user = sign_in_owner!
    conversation = create_conversation!(user: user, title: "Chat")

    post steer_current_turn_conversation_path(conversation),
         params: { content: "revised request" },
         as: :json

    assert_response :unprocessable_entity
    assert_includes response.body, "no_running_turn"
  end

  test "steer_current_turn still rejects when steer capability is disabled and no turn is running" do
    user = sign_in_owner!
    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "steer_capability" => false,
          },
        },
      )

    post steer_current_turn_conversation_path(conversation),
         params: { content: "revised request" },
         as: :json

    assert_response :unprocessable_entity
    assert_includes response.body, "no_running_turn"
  end

  test "steer_current_turn turbo stream replaces the message list and composer rail" do
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
    graph = conversation.dag_graph

    first = conversation.append_user_message!(content: "original request")
    agent = first.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [agent.id], claimed.map(&:id)

    post steer_current_turn_conversation_path(conversation),
         params: { content: "steered request" },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.media_type, "text/vnd.turbo-stream.html"

    list_id = ActionView::RecordIdentifier.dom_id(conversation, :messages_list)
    composer_rail_id = ActionView::RecordIdentifier.dom_id(conversation, :composer_status_rail)

    assert_includes response.body, %(turbo-stream action="replace" target="#{list_id}")
    assert_includes response.body, %(turbo-stream action="replace" target="#{composer_rail_id}")
    assert_includes response.body, "steered request"
  end

  test "steer_current_turn fallback preserves hash-like input policy overrides from the request" do
    user = sign_in_owner!
    conversation =
      create_conversation!(
        user: user,
        title: "Chat",
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "input_policy" => {
            "input_coalescing" => { "enabled" => false },
            "steer_capability" => false,
          },
        },
      )
    graph = conversation.dag_graph

    first = conversation.append_user_message!(content: "original request")
    original_user = first.fetch(:user_node)
    original_agent = first.fetch(:agent_node)

    claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
    assert_equal [original_agent.id], claimed.map(&:id)

    post steer_current_turn_conversation_path(conversation),
         params: {
           content: "fallback request",
           input_policy_override: {
             input_coalescing: { window_ms: 0 },
           },
         },
         as: :json

    assert_response :success

    new_agent = conversation.root_graph.nodes.active.where(node_type: Messages::AgentMessage.node_type_key).order(:id).last
    refute_equal original_agent.id, new_agent.id
    refute_equal original_user.turn_id, new_agent.turn_id
    assert_nil new_agent.claim_after_at
  end
end
