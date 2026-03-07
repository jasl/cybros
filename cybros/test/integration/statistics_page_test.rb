require "test_helper"

class StatisticsPageTest < ActionDispatch::IntegrationTest
  def sign_in!(email:, role: :owner)
    identity =
      Identity.create!(
        email: email,
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )
    user = User.create!(identity: identity, role: role)

    post session_path, params: { email: email, password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    user
  end

  def create_finished_agent_node!(conversation:, provider_key:, model_ref:, input_tokens:, output_tokens:, finished_at: nil)
    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")

    node = nil
    graph.mutate!(turn_id: turn_id) do |m|
      node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {
            "usage" => {
              "input_tokens" => input_tokens,
              "output_tokens" => output_tokens,
              "cache_creation_tokens" => 0,
              "cache_read_tokens" => 0,
            },
          },
        )
    end

    node.update_column(:finished_at, finished_at) if finished_at
    node.body.update!(output: { "provider_key" => provider_key, "model_ref" => model_ref })
    node
  end

  test "statistics page requires authentication" do
    get statistics_path
    assert_redirected_to new_session_path
  end

  test "statistics page shows per-user usage by model_ref" do
    user = sign_in!(email: "u@example.com")
    conversation = Conversation.create!(user: user, title: "C", metadata: { "agent" => { "agent_profile" => "coding" } })

    create_finished_agent_node!(conversation: conversation, provider_key: "openai", model_ref: "openai/gpt-5.4", input_tokens: 3, output_tokens: 7)

    get statistics_path
    assert_response :success
    assert_includes response.body, "openai/gpt-5.4"
    assert_includes response.body, "10"
  end

  test "statistics page shows by day and global by provider sections for owners" do
    user = sign_in!(email: "u@example.com")
    other_identity = Identity.create!(email: "other@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    other_user = User.create!(identity: other_identity, role: :owner)

    c1 = Conversation.create!(user: user, title: "C1", metadata: { "agent" => { "agent_profile" => "coding" } })
    c2 = Conversation.create!(user: other_user, title: "C2", metadata: { "agent" => { "agent_profile" => "coding" } })

    create_finished_agent_node!(
      conversation: c1,
      provider_key: "openai",
      model_ref: "openai/gpt-5.4",
      input_tokens: 3,
      output_tokens: 7,
      finished_at: Time.zone.parse("2026-03-06 12:00:00"),
    )
    create_finished_agent_node!(
      conversation: c2,
      provider_key: "openrouter",
      model_ref: "openrouter/openai-gpt-5.4",
      input_tokens: 2,
      output_tokens: 3,
      finished_at: Time.zone.parse("2026-03-05 12:00:00"),
    )

    get statistics_path
    assert_response :success
    assert_includes response.body, "By day"
    assert_includes response.body, "2026-03-06"
    assert_includes response.body, "Global by provider"
    assert_includes response.body, "openrouter"
  end

  test "statistics page hides global by provider section for non-admin users" do
    user = sign_in!(email: "member@example.com", role: :member)
    other_identity = Identity.create!(email: "other@example.com", password: "Passw0rd", password_confirmation: "Passw0rd")
    other_user = User.create!(identity: other_identity, role: :owner)

    c1 = Conversation.create!(user: user, title: "C1", metadata: { "agent" => { "agent_profile" => "coding" } })
    c2 = Conversation.create!(user: other_user, title: "C2", metadata: { "agent" => { "agent_profile" => "coding" } })

    create_finished_agent_node!(
      conversation: c1,
      provider_key: "openai",
      model_ref: "openai/gpt-5.4",
      input_tokens: 3,
      output_tokens: 7,
      finished_at: Time.zone.parse("2026-03-06 12:00:00"),
    )
    create_finished_agent_node!(
      conversation: c2,
      provider_key: "openrouter",
      model_ref: "openrouter/openai-gpt-5.4",
      input_tokens: 2,
      output_tokens: 3,
      finished_at: Time.zone.parse("2026-03-05 12:00:00"),
    )

    get statistics_path
    assert_response :success
    assert_includes response.body, "By day"
    assert_includes response.body, "2026-03-06"
    assert_not_includes response.body, "Global by provider"
    assert_not_includes response.body, "openrouter"
  end
end
