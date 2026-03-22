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
    agent = create_agent!(program: program)
    deployment = create_active_deployment!(program: program, endpoint_url: server.rpc_url)
    sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)
    conversation = create_conversation!(title: "Programmable context", agent: agent)

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      result = conversation.append_user_message!(content: "Inspect runtime context", model_ref: "dev/mock-model")
      agent_node = result.fetch(:agent_node)
      draft = RunDraft.order(:created_at).last
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

      run_claimed_nodes_until_idle!(graph: conversation.root_graph)

      expected_workspace = conversation.workspace_payload(lane_id: agent_node.lane_id)
      expected_prepare_session_context = {
        "account_id" => Account.instance.id,
        "user_id" => conversation.user_id,
        "conversation_id" => conversation.id,
      }
      expected_prepare_execution_context =
        expected_prepare_session_context.merge(
          "graph_id" => conversation.dag_graph.id,
          "lane_id" => agent_node.lane_id,
          "turn_id" => agent_node.turn_id,
          "dag_node_id" => agent_node.id,
          "execution_scope" => "primary",
        )
      expected_prepare_session_context = expected_prepare_session_context.merge("workspace" => expected_workspace)
      expected_prepare_execution_context = expected_prepare_execution_context.merge("workspace" => expected_workspace)
      expected_runtime_session_context = expected_prepare_session_context.merge("workspace" => expected_workspace)
      expected_runtime_execution_context = expected_prepare_execution_context.merge("workspace" => expected_workspace)

      assert_equal expected_prepare_session_context, captured_params.dig(:prepare, "session_context")
      assert_equal expected_runtime_session_context, captured_params.dig(:finalize, "session_context")
      assert_equal expected_prepare_execution_context, captured_params.dig(:prepare, "execution_context")
      assert_equal expected_runtime_execution_context, captured_params.dig(:finalize, "execution_context")

      runtime =
        Cybros::AgentRuntimeResolver.runtime_for(
          node: conversation.root_graph.nodes.find(agent_node.id),
          provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
          tools_registry: AgentCore::Resources::Tools::Registry.new,
          base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )
      built_context = AgentCore::DAG::ExecutionContextBuilder.build(node: conversation.root_graph.nodes.find(agent_node.id), runtime: runtime)

      assert_equal expected_runtime_session_context, built_context.attributes.dig(:cybros, :session_context)
      assert_equal expected_runtime_execution_context, built_context.attributes.dig(:cybros, :execution_context)
      assert_equal deployment.deployment_fingerprint, run.recognized_deployment.deployment_fingerprint
      assert_equal "finalized", draft.status
    end
  ensure
    llm_server&.shutdown
    server&.shutdown
  end

  test "execution reuses prepared attachment refs across planning hooks runtime hooks and the first llm call" do
    captured_params = {}
    attachment_import_calls = []
    llm_server =
      MockLLMServer.new do |_payload|
        MockLLMServer.chat_response(content: "llm draft answer")
      end.start
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "before_agent_step" => lambda do |params, base_result, _identity|
            captured_params[:prepare] = params.deep_dup
            base_result
          end,
          "before_finalize_output" => lambda do |params, base_result, _identity|
            captured_params[:finalize] = params.deep_dup
            base_result
          end,
          "attachments.import" => lambda do |params, base_result, _identity|
            attachment_import_calls << params.deep_dup
            base_result
          end,
        },
      ).start

    program = create_program!
    agent = create_agent!(program: program)
    deployment = create_active_deployment!(program: program, endpoint_url: server.rpc_url)
    sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)
    conversation = create_conversation!(title: "Programmable attachment execution", agent: agent)

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      result =
        conversation.append_user_message!(
          content: "Inspect runtime context",
          model_ref: "dev/mock-model",
          attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
        )
      agent_node = result.fetch(:agent_node)
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

      run_claimed_nodes_until_idle!(graph: conversation.root_graph)

      prepare_manifest = Array(captured_params.dig(:prepare, "attachment_manifest"))
      finalize_manifest = Array(captured_params.dig(:finalize, "attachment_manifest"))

      assert_equal 1, attachment_import_calls.length
      assert_equal 1, prepare_manifest.length
      assert_equal prepare_manifest, finalize_manifest
      assert_equal "attachment_import", prepare_manifest.dig(0, "kind")
      assert_equal "attachment_import", prepare_manifest.dig(0, "prepared_ref", "kind")
      assert_equal "attachment-note.txt", prepare_manifest.dig(0, "filename")

      preparation = ConversationAttachmentPreparation.order(:created_at).last
      assert_equal run.snapshot.dig("draft", "id"), preparation.run_draft_id
      assert_equal run.recognized_deployment_id, preparation.recognized_deployment_id
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

    child =
      Conversation.create!(
        user: parent.user,
        parent_conversation: parent,
        title: "Delegated",
        agent: parent.agent,
        agent_config_schema_fingerprint: parent.agent_config_schema_fingerprint,
        metadata: {
          "agent" => { "agent_profile" => "coding" },
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

    thread =
      SubagentThread.create!(
        id: ActiveRecord::Base.connection.select_value("select uuidv7()"),
        owner_conversation: parent,
        owner_graph: parent.dag_graph,
        owner_turn: DAG::Turn.find(parent_agent.turn_id),
        owner_node: parent_agent,
        child_conversation: child,
        child_graph: child.dag_graph,
        requested_name: "child",
        title: "Delegated",
        agent_profile: "subagent",
        context_turns: 50,
        diagnostic_level: "standard",
        status: "active",
        child_status: "pending",
        depth: 1,
        last_snapshot: {},
        final_snapshot: {},
      )

    child.update!(
      metadata: child.metadata.merge(
        "subagent_thread_id" => thread.id,
        "owner_conversation_id" => parent.id,
        "owner_graph_id" => parent.dag_graph.id,
        "owner_turn_id" => parent_agent.turn_id,
        "owner_node_id" => parent_agent.id,
        "depth" => 1,
      ),
    )

    runtime =
      Cybros::AgentRuntimeResolver.runtime_for(
        node: child.dag_graph.nodes.find(child_agent.id),
        provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
        tools_registry: AgentCore::Resources::Tools::Registry.new,
        base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )
    built_context = AgentCore::DAG::ExecutionContextBuilder.build(node: child.dag_graph.nodes.find(child_agent.id), runtime: runtime)
    expected_workspace = child.workspace_payload(lane_id: child_agent.lane_id)

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
          "subagent_id" => thread.id,
          "parent_turn_id" => parent_agent.turn_id,
          "parent_dag_node_id" => parent_agent.id,
          "depth" => 1,
        },
        "workspace" => expected_workspace,
      },
      built_context.attributes.dig(:cybros, :execution_context),
    )
  end

  private

    def create_program!
      create_agent_record!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: {
          "agent_key" => "fixture-program",
          "name" => "Fixture Program",
        },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
    end

    def create_active_deployment!(program:, endpoint_url:)
      fixture_identity = Cybros::ProgrammableAgentFixture.identity
      supported_methods = fixture_identity.fetch("supported_methods")
      create_runtime_binding_record!(
        agent: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: fixture_identity.fetch("deployment_fingerprint"),
        status: "active",
        health_status: "healthy",
        protocol_version: fixture_identity.fetch("protocol_version"),
        agent_sdk_version: fixture_identity.fetch("agent_sdk_version"),
        supported_methods: supported_methods,
        transport_config: {},
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {
          "agent_capabilities_version" => "fixture-agent-capabilities:v1",
          "observed_runtime_identity" => {
            "supported_methods" => supported_methods,
          },
        },
        inspection_details: {
          "identity" => {
            "deployment_fingerprint" => fixture_identity.fetch("deployment_fingerprint"),
          },
          "initialize" => {},
          "describe" => {},
          "health" => {},
          "schemas" => {},
        },
        activated_at: Time.current.change(usec: 0),
      )
    end

    def create_agent!(program:)
      materialize_agent_runtime!(
        agent: program,
        execution_profile: build_default_execution_profile!,
      )
    end

    def uploaded_fixture(name, content_type)
      Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/#{name}"), content_type)
    end

    def run_claimed_nodes_until_idle!(graph:)
      10.times do
        graph.nodes.active.where.not(claim_after_at: nil).update_all(claim_after_at: nil)
        claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
        return if claimed.empty?

        claimed.each do |node|
          DAG::Runner.run_node!(node.id)
        end
      end

      flunk "expected graph to become idle"
    end
end
