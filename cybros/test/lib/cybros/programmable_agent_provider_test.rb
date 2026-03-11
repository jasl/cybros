require "test_helper"

class Cybros::ProgrammableAgentProviderTest < ActiveSupport::TestCase
  class DelegateProvider < AgentCore::Resources::Provider::Base
    attr_reader :calls

    def initialize
      @calls = []
    end

    def name = "delegate_provider"
    def model_ref = "openai/gpt-5.4"
    def api_model = "gpt-5.4"
    def last_call_metadata = { "delegate" => true }

    def chat(messages:, model:, tools: nil, stream: false, **options)
      @calls << {
        messages: messages,
        model: model,
        tools: tools,
        stream: stream,
        options: options,
      }

      AgentCore::Resources::Provider::Response.new(
        message: AgentCore::Message.new(role: :assistant, content: "delegate response"),
        stop_reason: :end_turn,
      )
    end
  end

  test "chat delegates to the wrapped llm provider instead of invoking turn compose" do
    conversation = create_conversation!
    turn = conversation.append_user_message!(content: "Hello")
    agent = turn.fetch(:agent_node)
    run = create_conversation_run!(conversation: conversation, node: agent)
    delegate = DelegateProvider.new

    provider = Cybros::ProgrammableAgentProvider.new(conversation_run: run, delegate: delegate)
    response =
      provider.chat(
        messages: [AgentCore::Message.new(role: :user, content: "Hi")],
        model: "gpt-5.4",
        tools: [{ "type" => "function", "name" => "echo" }],
        stream: false,
        temperature: 0.2,
      )

    assert_equal "delegate response", response.message.text
    assert_equal "delegate_provider", provider.delegate_name
    assert_equal 1, delegate.calls.size
    assert_equal "gpt-5.4", delegate.calls.dig(0, :model)
    assert_equal true, provider.last_call_metadata["delegate"]
    assert_equal run.snapshot.dig("draft", "planning", "tool_surface"), provider.last_call_metadata["tool_surface"]
    assert_equal delegate.name, provider.last_call_metadata.fetch("delegate_name")
  end

  test "on_context_pressure uses a unique invocation id per runtime node within the same conversation run" do
    observed_request_node_ids = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "on_context_pressure" => lambda do |params, _base_result, _identity|
            observed_request_node_ids << params.dig("execution_context", "dag_node_id")
            {
              "actions" => [
                {
                  "type" => "noop",
                },
              ],
            }
          end,
        },
      ).start

    conversation = create_conversation!
    turn = conversation.append_user_message!(content: "Hello")
    first_agent = turn.fetch(:agent_node)
    second_agent = nil

    conversation.root_graph.mutate!(turn_id: first_agent.turn_id) do |m|
      second_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: conversation.chat_lane.id,
          metadata: {},
        )
      m.create_edge(from_node: first_agent, to_node: second_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    run = create_conversation_run!(conversation: conversation, node: first_agent)
    deployment = run.agent_deployment
    deployment.update!(
      endpoint_url: server.rpc_url,
      deployment_bearer_secret_ref: "secret://fixture",
      supported_methods: AgentDeployments::REQUIRED_METHODS + %w[on_context_pressure],
    )

    provider = Cybros::ProgrammableAgentProvider.new(conversation_run: run, delegate: DelegateProvider.new)
    prompt =
      Struct.new(:system_prompt, :messages, :tools, :options).new(
        "",
        [{ "role" => "user", "content" => "Hello" }],
        [],
        {},
      )

    provider.run_on_context_pressure!(
      node: first_agent,
      built_prompt: prompt,
      context_pressure: {
        "budget_state" => "soft_limit_reached",
        "budget_action" => "advise_compact",
      },
    )
    provider.run_on_context_pressure!(
      node: second_agent,
      built_prompt: prompt,
      context_pressure: {
        "budget_state" => "soft_limit_reached",
        "budget_action" => "enqueue_compact",
      },
    )

    invocations =
      AgentRPCInvocation.where(scope_type: "conversation_run", scope_id: run.id, method: "on_context_pressure")
        .order(:created_at)
        .to_a

    assert_equal 2, invocations.size
    refute_equal invocations.first.invocation_id, invocations.second.invocation_id
    assert_equal [first_agent.id.to_s, second_agent.id.to_s], observed_request_node_ids
  ensure
    server&.shutdown
  end

  test "before_finalize_output uses a unique invocation id per runtime node within the same conversation run" do
    observed_request_node_ids = []
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "before_finalize_output" => lambda do |params, _base_result, _identity|
            observed_request_node_ids << params.dig("execution_context", "dag_node_id")
            {
              "actions" => [
                {
                  "type" => "emit_message",
                  "message" => {
                    "role" => "assistant",
                    "content" => "finalized #{params.dig("execution_context", "dag_node_id")}",
                  },
                },
              ],
            }
          end,
        },
      ).start

    conversation = create_conversation!
    turn = conversation.append_user_message!(content: "Hello")
    first_agent = turn.fetch(:agent_node)
    second_agent = nil

    conversation.root_graph.mutate!(turn_id: first_agent.turn_id) do |m|
      second_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          lane_id: conversation.chat_lane.id,
          metadata: {},
        )
      m.create_edge(from_node: first_agent, to_node: second_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    run = create_conversation_run!(conversation: conversation, node: first_agent)
    deployment = run.agent_deployment
    deployment.update!(
      endpoint_url: server.rpc_url,
      deployment_bearer_secret_ref: "secret://fixture",
      supported_methods: AgentDeployments::REQUIRED_METHODS + %w[before_finalize_output],
    )

    provider = Cybros::ProgrammableAgentProvider.new(conversation_run: run, delegate: DelegateProvider.new)
    prompt =
      Struct.new(:system_prompt, :messages, :tools, :options).new(
        "",
        [{ "role" => "user", "content" => "Hello" }],
        [],
        {},
      )

    first_result =
      provider.run_before_finalize_output!(
        node: first_agent,
        built_prompt: prompt,
        draft_output: { "content" => "draft one" },
      )
    second_result =
      provider.run_before_finalize_output!(
        node: second_agent,
        built_prompt: prompt,
        draft_output: { "content" => "draft two" },
      )

    invocations =
      AgentRPCInvocation.where(scope_type: "conversation_run", scope_id: run.id, method: "before_finalize_output")
        .order(:created_at)
        .to_a

    assert_equal 2, invocations.size
    refute_equal invocations.first.invocation_id, invocations.second.invocation_id
    assert_equal "finalized #{first_agent.id}", first_result.emitted_message.fetch("content")
    assert_equal "finalized #{second_agent.id}", second_result.emitted_message.fetch("content")
    assert_equal [first_agent.id.to_s, second_agent.id.to_s], observed_request_node_ids
  ensure
    server&.shutdown
  end

  private

    def create_conversation_run!(conversation:, node:)
      program =
        AgentProgram.create!(
          name: "Fixture Program",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_program_key" => "fixture-program", "name" => "Fixture Program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      deployment =
        AgentDeployment.create!(
          agent_program: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: "http://127.0.0.1:4319/rpc",
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: "contract:v1",
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: AgentDeployments::REQUIRED_METHODS,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {
            "capability_registry_snapshot_id" => "cap:test",
          },
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )

      ConversationRun.create!(
        conversation: conversation,
        dag_node_id: node.id,
        state: "queued",
        queued_at: Time.current.change(usec: 0),
        snapshot_version: 1,
        initiated_by_user: conversation.user,
        effective_permission_mode: "default",
        agent_program: program,
        contract_fingerprint: "contract:v1",
        agent_deployment: deployment,
        deployment_fingerprint: "fixture-deployment-v1",
        deployment_activated_at: deployment.activated_at,
        selected_model_ref: "openai/gpt-5.4",
        effective_public_settings: {},
        effective_agent_config: {},
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
        effective_policy: {},
        runtime_governors: {
          "provider_limiter" => {
            "provider_key" => "openai",
          },
        },
        snapshot: {
          "draft" => {
            "id" => SecureRandom.uuid,
            "planning" => {
              "tool_surface" => {
                "capability_registry_snapshot_id" => "cap:test",
                "selected_tool_ids" => [],
              },
            },
          },
        },
      )
    end
end
