require "test_helper"
require "ostruct"

class Cybros::AgentRuntimeResolverModelRefTest < ActiveSupport::TestCase
  def with_stubbed_singleton_method(obj, method_name, value:)
    original = obj.method(method_name)
    obj.define_singleton_method(method_name) do |*_args, **_kwargs|
      value.respond_to?(:call) ? value.call(*_args, **_kwargs) : value
    end
    yield
  ensure
    obj.define_singleton_method(method_name) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
  end

  def build_pending_agent_node(conversation:, metadata: {})
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
          metadata: metadata,
        )

      m.create_edge(from_node: user, to_node: node, edge_type: DAG::Edge::SEQUENCE)
    end

    node
  end

  test "explicit model_ref hard-errors when provider credential is missing" do
    LLMProvider.delete_all

    conversation = create_conversation!
    node = build_pending_agent_node(conversation: conversation, metadata: { "llm" => { "model_ref" => "openai/gpt-5.4" } })

    error = assert_raises(AgentCore::ValidationError) { Cybros::AgentRuntimeResolver.runtime_for(node: node) }
    assert_equal "cybros.llm.credential_missing", error.code
  end

  test "conversation-level stored model_ref applies when node metadata has no explicit llm selection" do
    LLMProvider.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")

    conversation = create_conversation!(metadata: { "llm" => { "model_ref" => "openai/gpt-5.4" } })
    node = build_pending_agent_node(conversation: conversation, metadata: {})

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
    assert_equal "gpt-5.4", runtime.model
  end

  test "explicit model_ref hard-errors when model_ref is invalid" do
    LLMProvider.delete_all
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "k1")

    conversation = create_conversation!
    node = build_pending_agent_node(conversation: conversation, metadata: { "llm" => { "model_ref" => "openai/does-not-exist" } })

    error = assert_raises(AgentCore::ValidationError) { Cybros::AgentRuntimeResolver.runtime_for(node: node) }
    assert_equal "cybros.llm.model_not_found", error.code
  end

  test "explicit codex_subscription model_ref builds responses provider with bearer headers" do
    LLMProvider.delete_all
    ensure_llm_provider!(
      provider_key: "codex_subscription",
      credential_type: "oauth_codex",
      access_token: "at",
      refresh_token: "rt",
      expires_at: Time.current + 3600,
      account_id: "acc_1",
    )

    conversation = create_conversation!
    node =
      build_pending_agent_node(
        conversation: conversation,
        metadata: { "llm" => { "model_ref" => "codex_subscription/gpt-5.3-codex" } },
      )

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
    provider = runtime.provider
    assert_equal "codex_subscription", provider.name

    delegate = provider.instance_variable_get(:@delegate)
    assert_equal :responses, delegate.instance_variable_get(:@wire_api)

    client_options = delegate.instance_variable_get(:@client_options)
    headers = client_options.fetch(:headers)
    assert_equal "Bearer at", headers.fetch("Authorization")
    assert_equal "acc_1", headers.fetch("ChatGPT-Account-Id")
  end

  test "explicit codex_subscription model_ref rejects tool calls at capability gate" do
    LLMProvider.delete_all
    ensure_llm_provider!(
      provider_key: "codex_subscription",
      credential_type: "oauth_codex",
      access_token: "at",
      refresh_token: "rt",
      expires_at: Time.current + 3600,
      account_id: "acc_1",
    )

    conversation = create_conversation!
    node =
      build_pending_agent_node(
        conversation: conversation,
        metadata: { "llm" => { "model_ref" => "codex_subscription/gpt-5.3-codex" } },
      )

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
    provider = runtime.provider
    delegate = provider.instance_variable_get(:@delegate)

    stub_client =
      Class.new do
        attr_reader :calls

        def initialize
          @calls = []
        end

        def responses(**kwargs)
          @calls << kwargs
          OpenStruct.new(
            output_text: "",
            usage: { "input_tokens" => 1, "output_tokens" => 1 },
            output_items: [
              { "type" => "function_call", "call_id" => "call_1", "name" => "t", "arguments" => "{}" },
            ],
            response: OpenStruct.new(body: {}),
          )
        end
      end.new

    delegate.instance_variable_set(:@client, stub_client)

    response = provider.chat(messages: [AgentCore::Message.new(role: :user, content: "hi")], model: runtime.model, tools: [{ name: "t" }], stream: false)
    assert response.has_tool_calls?
    assert_equal "t", response.tool_calls.first.name
    assert_equal 1, stub_client.calls.length
  end

  test "explicit codex_subscription model_ref accepts image input and serializes responses image content" do
    LLMProvider.delete_all
    ensure_llm_provider!(
      provider_key: "codex_subscription",
      credential_type: "oauth_codex",
      access_token: "at",
      refresh_token: "rt",
      expires_at: Time.current + 3600,
      account_id: "acc_1",
    )

    conversation = create_conversation!
    node =
      build_pending_agent_node(
        conversation: conversation,
        metadata: { "llm" => { "model_ref" => "codex_subscription/gpt-5.3-codex" } },
      )

    runtime = Cybros::AgentRuntimeResolver.runtime_for(node: node)
    provider = runtime.provider
    delegate = provider.instance_variable_get(:@delegate)

    stub_client =
      Class.new do
        attr_reader :calls

        def initialize
          @calls = []
        end

        def responses(**kwargs)
          @calls << kwargs
          OpenStruct.new(
            output_text: "ok",
            usage: { "input_tokens" => 1, "output_tokens" => 1 },
            output_items: [],
            response: OpenStruct.new(body: {}),
          )
        end
      end.new

    delegate.instance_variable_set(:@client, stub_client)

    provider.chat(
      messages: [
        AgentCore::Message.new(
          role: :user,
          content: [
            AgentCore::TextContent.new(text: "look at this"),
            AgentCore::ImageContent.new(source_type: :base64, data: "AA==", media_type: "image/png"),
          ],
        ),
      ],
      model: runtime.model,
      stream: false,
    )

    input = stub_client.calls.first.fetch(:input)
    content = input.first.fetch("content")
    assert_equal "input_text", content.first.fetch("type")
    assert_equal "input_image", content.second.fetch("type")
    assert_equal "data:image/png;base64,AA==", content.second.fetch("image_url")
  end

  test "explicit codex_subscription model_ref hard-errors when oauth refresh fails" do
    LLMProvider.delete_all
    ensure_llm_provider!(
      provider_key: "codex_subscription",
      credential_type: "oauth_codex",
      access_token: "old-at",
      refresh_token: "rt",
      expires_at: Time.current - 60,
      account_id: "acc_1",
    )

    conversation = create_conversation!
    node =
      build_pending_agent_node(
        conversation: conversation,
        metadata: { "llm" => { "model_ref" => "codex_subscription/gpt-5.3-codex" } },
      )

    error =
      with_stubbed_singleton_method(
        Cybros::LLM::CodexOAuth,
        :refresh_if_needed!,
        value: ->(*_args, **_kwargs) { raise Cybros::LLM::CodexOAuthError.new("Refresh failed: invalid_grant", error_code: "invalid_grant") },
      ) do
        assert_raises(AgentCore::ValidationError) { Cybros::AgentRuntimeResolver.runtime_for(node: node) }
      end

    assert_equal "cybros.llm.oauth_refresh_failed", error.code
  end

  test "explicit dev model_ref hard-errors when provider is not enabled in the current environment" do
    conversation = create_conversation!
    node = build_pending_agent_node(conversation: conversation, metadata: { "llm" => { "model_ref" => "dev/mock-model" } })
    production_env = ActiveSupport::StringInquirer.new("production")

    error =
      with_stubbed_singleton_method(Rails, :env, value: production_env) do
        assert_raises(AgentCore::ValidationError) { Cybros::AgentRuntimeResolver.runtime_for(node: node) }
      end

    assert_equal "cybros.llm.provider_unavailable_in_environment", error.code
  end
end
