require "test_helper"

class ConversationLongOutputTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "terminal markdown rendering truncates extremely long output to keep DOM bounded" do
    user = create_user!
    sign_in!(user)

    conversation = create_conversation!(user: user, title: "Chat")
    graph = conversation.dag_graph

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
        )
    end

    long = ("a" * 24_900) + "TAILMARK"

    DAG::NodeBody.where(id: agent.body_id).update_all(
      output: { "content" => long },
      output_preview: { "content" => long.first(2000) },
      updated_at: Time.current,
    )

    get conversation_path(conversation)
    assert_response :success

    assert_includes response.body, %(data-controller="markdown")
    assert_includes response.body, "… (truncated)"
    refute_includes response.body, "TAILMARK"
  end
end
