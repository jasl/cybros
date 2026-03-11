require "test_helper"
require_relative "../support/programmable_agent_runtime_test_support"

class ProgrammableAgentExecutionContextTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProgrammableAgentRuntimeTestSupport

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "planning and run-bound programmable agent rpc payloads include typed session and execution context" do
    captured_params = {}
    llm_server =
      MockLLMServer.new do |_payload|
        MockLLMServer.chat_response(content: "llm draft answer")
      end.start
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            captured_params[:prepare] = params.deep_dup
            base_result
          end,
          "before_finalize_output" => lambda do |params, base_result, _identity|
            captured_params[:finalize] = params.deep_dup
            base_result
          end,
        },
      ).start

    program = create_program!
    deployment = create_active_deployment!(program: program, endpoint_url: server.rpc_url)
    conversation = create_conversation!(title: "Programmable context", agent_program: program)

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      result = conversation.append_user_message!(content: "Inspect runtime context", model_ref: "dev/mock-model")
      agent_node = result.fetch(:agent_node)
      draft = RunDraft.order(:created_at).last
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

      conversation.root_graph.nodes.find(agent_node.id).update!(claim_after_at: nil)
      assert_includes DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id), agent_node.id

      DAG::Runner.run_node!(agent_node.id)

      expected_session_context = {
        "account_id" => Account.instance.id,
        "user_id" => conversation.user_id,
        "conversation_id" => conversation.id,
      }
      expected_execution_context =
        expected_session_context.merge(
          "graph_id" => conversation.dag_graph.id,
          "lane_id" => agent_node.lane_id,
          "turn_id" => agent_node.turn_id,
          "dag_node_id" => agent_node.id,
          "execution_scope" => "primary",
        )

      assert_equal expected_session_context, captured_params.dig(:prepare, "session_context")
      assert_equal expected_session_context, captured_params.dig(:finalize, "session_context")
      assert_equal expected_execution_context, captured_params.dig(:prepare, "execution_context")
      assert_equal expected_execution_context, captured_params.dig(:finalize, "execution_context")

      runtime =
        Cybros::AgentRuntimeResolver.runtime_for(
          node: conversation.root_graph.nodes.find(agent_node.id),
          provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )
      built_context = AgentCore::DAG::ExecutionContextBuilder.build(node: conversation.root_graph.nodes.find(agent_node.id), runtime: runtime)

      assert_equal expected_session_context, built_context.attributes.dig(:cybros, :session_context)
      assert_equal expected_execution_context, built_context.attributes.dig(:cybros, :execution_context)
      assert_equal deployment.id, run.agent_deployment_id
      assert_equal "finalized", draft.status
    end
  ensure
    llm_server&.shutdown
    server&.shutdown
  end

  test "runtime execution context exposes subagent identity for delegated conversations" do
    parent = create_conversation!(title: "Parent")
    parent_turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    parent_agent = nil

    parent.dag_graph.mutate!(turn_id: parent_turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Delegate this",
          metadata: {},
        )

      parent_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: parent_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    subagent_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    child =
      Conversation.create!(
        user: parent.user,
        parent_conversation: parent,
        title: "Delegated",
        agent_program: parent.agent_program,
        agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
        default_execution_target: parent.default_execution_target,
        metadata: {
          "agent" => { "agent_profile" => "coding" },
          "subagent" => {
            "subagent_id" => subagent_id,
            "parent_conversation_id" => parent.id.to_s,
            "parent_graph_id" => parent.dag_graph.id.to_s,
            "spawned_from_node_id" => parent_agent.id.to_s,
          },
        },
      )

    child_turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
    child_agent = nil

    child.dag_graph.mutate!(turn_id: child_turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "Do delegated work",
          metadata: {},
        )

      child_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {},
        )

      m.create_edge(from_node: user, to_node: child_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    runtime =
      Cybros::AgentRuntimeResolver.runtime_for(
        node: child.dag_graph.nodes.find(child_agent.id),
        provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )
    built_context = AgentCore::DAG::ExecutionContextBuilder.build(node: child.dag_graph.nodes.find(child_agent.id), runtime: runtime)

    assert_equal(
      {
        "account_id" => Account.instance.id,
        "user_id" => child.user_id,
        "conversation_id" => child.id,
        "graph_id" => child.dag_graph.id,
        "lane_id" => child_agent.lane_id,
        "turn_id" => child_agent.turn_id,
        "dag_node_id" => child_agent.id,
        "execution_scope" => "subagent",
        "subagent" => {
          "subagent_id" => subagent_id,
          "parent_turn_id" => parent_agent.turn_id,
          "parent_dag_node_id" => parent_agent.id,
        },
      },
      built_context.attributes.dig(:cybros, :execution_context),
    )
  end

  private

    def create_program!
      AgentProgram.create!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: {
          "agent_program_key" => "fixture-program",
          "name" => "Fixture Program",
        },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
    end

    def create_active_deployment!(program:, endpoint_url:)
      AgentDeployment.create!(
        agent_program: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "fixture-deployment-v1",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: AgentDeployments::REQUIRED_METHODS,
        transport_config: {},
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {
          "identity" => {
            "deployment_fingerprint" => "fixture-deployment-v1",
          },
          "initialize" => {},
          "describe" => {},
          "health" => {},
          "schemas" => {},
        },
        activated_at: Time.current.change(usec: 0),
      )
    end
end
