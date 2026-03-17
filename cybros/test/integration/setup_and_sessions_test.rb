require "test_helper"

class SetupAndSessionsTest < ActionDispatch::IntegrationTest
  def reset_install_state!
    # Some tests disable transactions and can leave rows behind; this suite needs a truly empty
    # "fresh install" state (no identities) without tripping foreign keys.
    AgentRPCInvocation.update_all(last_session_id: nil)
    AgentRPCOperationReceipt.delete_all
    AgentRPCSession.delete_all
    AgentRPCInvocation.delete_all
    ConversationRun.delete_all
    RunDraft.delete_all
    Event.delete_all
    TurnInternalTask.delete_all
    Conversation.delete_all
    RecognizedDeployment.delete_all
    Agent.delete_all
    Session.delete_all
    User.delete_all
    Identity.delete_all

    DAG::NodeEvent.delete_all
    DAG::Edge.delete_all
    DAG::Node.delete_all
    DAG::NodeBody.delete_all
    DAG::Graph.delete_all
  end

  test "reset_install_state! clears queued turn internal tasks before deleting conversations" do
    conversation = create_conversation!(title: "Fresh install cleanup")
    graph = conversation.dag_graph
    lane = conversation.chat_lane
    turn = graph.turns.create!(lane: lane, metadata: {})
    source_node =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::FINISHED,
        lane: lane,
        turn: turn,
        metadata: {},
      )

    TurnInternalTask.create!(
      conversation: conversation,
      graph: graph,
      lane: lane,
      turn: turn,
      source_node: source_node,
      source_hook_name: "after_task_notice",
      source_fingerprint: "fresh-install-cleanup",
      logical_tool_name: "subagent_spawn",
      input: { "name" => "cleanup-check" },
      authored_metadata: { "source" => "test" },
      execution_mode: "serial",
      queue_position: 10,
      status: "queued",
    )

    assert_nothing_raised { reset_install_state! }
    assert_equal 0, TurnInternalTask.count
    assert_equal 0, Conversation.count
  end

  test "root redirects to setup when no identities exist" do
    reset_install_state!

    get root_path
    assert_redirected_to new_setup_path
  end

  test "setup wizard uses the session layout" do
    reset_install_state!

    get new_setup_path
    assert_response :success
    assert_includes response.body, 'data-layout="session"'
  end

  test "setup wizard creates initial identity and signs in" do
    reset_install_state!

    get new_setup_path
    assert_response :success
    assert_includes response.body, 'data-layout="session"'

    assert_difference -> { Identity.count }, +1 do
      assert_difference -> { User.count }, +1 do
        assert_difference -> { Session.count }, +1 do
          post setup_path, params: {
            identity: {
              email: "admin@example.com",
              password: "Passw0rd",
              password_confirmation: "Passw0rd",
            },
          }
        end
      end
    end

    assert_redirected_to root_path
    assert cookies[:session_token].present?

    follow_redirect!
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_includes response.body, 'data-layout="agent"'

    agent = Agent.find_by!(bundled_agent_key: "claw")
    deployment = agent.active_runtime_binding
    assert_equal "bundled", agent.source_kind
    assert_equal "claw", agent.bundled_agent_key
    assert_equal "healthy", deployment&.health_status
    assert_equal "active", deployment&.status
  end

  test "setup wizard is not accessible after initial identity exists" do
    Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")

    get new_setup_path
    assert_redirected_to root_path
  end

  test "sessions new redirects to setup when no identities exist" do
    reset_install_state!

    get new_session_path
    assert_redirected_to new_setup_path
  end

  test "sessions new uses the session layout" do
    reset_install_state!
    Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")

    get new_session_path
    assert_response :success
    assert_includes response.body, 'data-layout="session"'
  end

  test "sessions create authenticates with email and password and sets cookie" do
    identity = Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "root renders landing when not authenticated" do
    identity = Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    User.create!(identity: identity, role: :owner)

    get root_path
    assert_response :success
    assert_includes response.body, 'data-layout="landing"'
  end

  test "sessions create with invalid credentials re-renders and does not set cookie" do
    identity = Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "wrong" }
    assert_response :unprocessable_entity
    assert_not cookies[:session_token].present?
  end

  test "sessions destroy clears cookie" do
    identity = Identity.create!(email: "admin@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert cookies[:session_token].present?

    delete session_path
    assert_redirected_to new_session_path
    assert_not cookies[:session_token].present?
  end
end
