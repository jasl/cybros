require "test_helper"

class Cybros::AgentRuntimeResolverLlmProviderTest < ActiveSupport::TestCase
  def with_env(values)
    prior = {}
    values.each do |key, value|
      prior[key] = ENV[key]
      ENV[key] = value
    end

    yield
  ensure
    prior.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  def build_pending_agent_node(conversation:)
    graph = conversation.dag_graph
    turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")

    node = nil
    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Hello",
          metadata: {},
        )

      node =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: node, edge_type: DAG::Edge::SEQUENCE)
    end

    node
  end

  test "runtime_for selects model_ref preference when available in YAML catalog" do
    LLMProvider.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
              "agent_program" => { "model_prefer" => ["openai/gpt-5.4"] },
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)

    provider = runtime.provider
    assert_equal "openai", provider.name
    assert_equal "gpt-5.4", runtime.model

    # Implementation detail, but needed to prove DB-driven selection without making a network call.
    client_options = provider.instance_variable_get(:@delegate).instance_variable_get(:@client_options)
    assert_equal "https://api.openai.com/v1", client_options.fetch(:base_url)
  end

  test "runtime_for ignores preferences for providers requiring missing credentials" do
    LLMProvider.delete_all

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
            "agent_program" => { "model_prefer" => ["codex_subscription/gpt-5.3-codex"] },
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    error = assert_raises(AgentCore::ValidationError) { Cybros::AgentRuntimeResolver.runtime_for(node: node) }
    assert_equal "cybros.llm.model_preference_unavailable", error.code
  end

  test "runtime_for uses site default when agent prefer is absent" do
    LLMProvider.delete_all
    ensure_llm_provider!(provider_key: "openrouter", credential_type: "api_key", api_key: "sk-or-test")
    Account.instance.update_llm_default_model_ref!("openrouter/openai-gpt-5.4")

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
    assert_equal "openai/gpt-5.4", runtime.model
  end

  test "runtime_for falls back to catalog default when site default no longer exists" do
    LLMProvider.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")
    Account.instance.update_llm_default_model_ref!("openai/does-not-exist")

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
    assert_equal "gpt-5.4", runtime.model
  end

  test "runtime_for hard-errors when site default exists but is not currently usable" do
    LLMProvider.delete_all
    Account.instance.update_llm_default_model_ref!("openai/gpt-5.4")

    conversation =
      create_conversation!(
        metadata: {
          "agent" => {
            "agent_profile" => "coding",
          },
        },
      )
    node = build_pending_agent_node(conversation: conversation)

    error = assert_raises(AgentCore::ValidationError) { Cybros::AgentRuntimeResolver.runtime_for(node: node) }
    assert_equal "cybros.llm.credential_missing", error.code
  end
end
