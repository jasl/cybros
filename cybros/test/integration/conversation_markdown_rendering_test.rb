require "test_helper"

class ConversationMarkdownRenderingTest < ActionDispatch::IntegrationTest
  def sign_in!(user, password: "Passw0rd")
    post session_path, params: { email: user.identity.email, password: password }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "terminal agent message renders markdown template + output container on conversation page" do
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

    DAG::NodeBody.where(id: agent.body_id).update_all(
      output: { "content" => "# Hello\\n\\n- a\\n- b" },
      output_preview: { "content" => "# Hello" },
      updated_at: Time.current,
    )

    get conversation_path(conversation)
    assert_response :success
    assert_includes response.body, %(data-controller="markdown")
    assert_includes response.body, %(data-markdown-target="content")
    assert_includes response.body, %(data-markdown-target="output")
  end
end
