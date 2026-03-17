require "test_helper"
require "fileutils"
require "tmpdir"

class Cybros::ProgrammableAgent::ToolExecutionTest < ActiveSupport::TestCase
  test "tool execution payload includes typed session and execution context with workspace" do
    workspace_root = Dir.mktmpdir("cybros-tool-execution-")

    with_default_agent_workspace_root(workspace_root) do
      program =
        create_agent_record!(
          name: "Fixture Program",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_key" => "fixture-program", "name" => "Fixture Program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      target = build_default_execution_profile!
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: "http://127.0.0.1:4319/rpc",
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Agents::Protocol::REQUIRED_METHODS + ["tool.execute"],
          capability_snapshot: {
            "agent_capabilities_version" => "fixture-agent-capabilities:v1",
          },
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      agent = materialize_agent_runtime!(agent: program, execution_profile: target, deployment: deployment)
      recognized_deployment = recognize_agent_runtime!(agent: agent, deployment: deployment)
      conversation = create_conversation!(title: "Tool execution", agent: agent)
      turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
      agent_node = nil

      conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
        user =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            lane_id: conversation.chat_lane.id,
            content: "Inspect the file",
            metadata: {},
          )
        agent_node =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            lane_id: conversation.chat_lane.id,
            metadata: {},
          )

        m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
      end
      Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      conversation.reload

      run =
        create_conversation_run!(
          conversation: conversation,
          dag_node_id: agent_node.id,
          agent: agent,
          recognized_deployment: recognized_deployment,
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          effective_policy: {},
          snapshot: {},
        )

      captured = nil

      lifecycle_singleton = AgentRPC::LifecycleCaller.singleton_class
      original_call = lifecycle_singleton.instance_method(:call!)
      lifecycle_singleton.define_method(:call!) do |**kwargs|
        captured = kwargs
        { "result" => { "content" => [], "error" => false, "metadata" => {} } }
      end

      begin
        Cybros::ProgrammableAgent::ToolExecution.call!(
          conversation_run: run,
          tool_call_id: "tc_read",
          logical_tool_name: "read",
          effective_tool_id: "etool_read",
          implementation_ref: "claw:read",
          capability_registry_snapshot_id: "csnap_fixture",
          tool_surface_id: "surface_fixture",
          arguments: { "path" => "README.md" },
        )
      ensure
        lifecycle_singleton.define_method(:call!, original_call)
      end

      expected_workspace = conversation.workspace_payload(lane_id: conversation.chat_lane.id)

      assert_equal expected_workspace, captured.dig(:request_payload, "session_context", "workspace")
      assert_equal expected_workspace, captured.dig(:request_payload, "execution_context", "workspace")
      assert_equal "primary", captured.dig(:request_payload, "execution_context", "execution_scope")
      assert_equal agent_node.id, captured.dig(:request_payload, "execution_context", "dag_node_id")
    end
  ensure
    FileUtils.rm_rf(workspace_root) if workspace_root.present?
  end

  test "tool execution limits callback sessions to conversation memory methods" do
    workspace_root = Dir.mktmpdir("cybros-tool-execution-")
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start

    with_default_agent_workspace_root(workspace_root) do
      runtime = create_runtime!(endpoint_url: server.rpc_url, deployment_bearer_secret_ref: "secret://fixture")
      captured = nil

      lifecycle_singleton = AgentRPC::LifecycleCaller.singleton_class
      original_call = lifecycle_singleton.instance_method(:call!)
      lifecycle_singleton.define_method(:call!) do |**kwargs|
        captured = kwargs
        { "result" => { "content" => [], "error" => false, "metadata" => {} } }
      end

      begin
        Cybros::ProgrammableAgent::ToolExecution.call!(
          conversation_run: runtime.fetch(:run),
          tool_call_id: "tc_memory_get",
          logical_tool_name: "memory_get",
          effective_tool_id: "etool_memory_get",
          implementation_ref: "claw:memory_get",
          capability_registry_snapshot_id: "csnap_fixture",
          tool_surface_id: "surface_fixture",
          arguments: {},
        )
      ensure
        lifecycle_singleton.define_method(:call!, original_call)
      end

      assert_equal(
        %w[conversation.memory.get conversation.memory.put conversation.memory.append],
        captured.fetch(:allowed_callback_methods),
      )

      opened =
        AgentRPC::SessionAuthorizer.open!(
          deployment: runtime.fetch(:deployment),
          conversation: runtime.fetch(:conversation),
          scope_type: "conversation_run",
          scope_id: runtime.fetch(:run).id,
          allowed_methods: captured.fetch(:allowed_callback_methods),
        )

      authorized =
        AgentRPC::SessionAuthorizer.authorize_callback!(
          bearer: opened.fetch(:session_bearer),
          method_name: "conversation.memory.get",
          scope_type: "conversation_run",
          scope_id: runtime.fetch(:run).id,
        )

      assert_equal opened.fetch(:session).id, authorized.id

      error =
        assert_raises(AgentCore::ValidationError) do
          AgentRPC::SessionAuthorizer.authorize_callback!(
            bearer: opened.fetch(:session_bearer),
            method_name: "lane.kv.list",
            scope_type: "conversation_run",
            scope_id: runtime.fetch(:run).id,
          )
        end

      assert_equal "cybros.agent_rpc.callback_method_not_allowed", error.code
    end
  ensure
    server&.shutdown
    FileUtils.rm_rf(workspace_root) if workspace_root.present?
  end

  private

    def create_runtime!(endpoint_url:, deployment_bearer_secret_ref:)
      program =
        create_agent_record!(
          name: "Fixture Program",
          config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "agent_key" => "fixture-program", "name" => "Fixture Program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      target = build_default_execution_profile!
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: endpoint_url,
          deployment_bearer_secret_ref: deployment_bearer_secret_ref,
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "fixture-deployment-v1",
          status: "active",
          health_status: "healthy",
          protocol_version: "agent_rpc.v1",
          agent_sdk_version: "fixture-ruby-sdk/1.0",
          supported_methods: Agents::Protocol::REQUIRED_METHODS + ["tool.execute"],
          capability_snapshot: {
            "agent_capabilities_version" => "fixture-agent-capabilities:v1",
          },
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      agent = materialize_agent_runtime!(agent: program, execution_profile: target, deployment: deployment)
      recognized_deployment = recognize_agent_runtime!(agent: agent, deployment: deployment)
      conversation = create_conversation!(title: "Tool execution", agent: agent)
      turn_id = ActiveRecord::Base.connection.select_value("select uuidv7()")
      agent_node = nil

      conversation.dag_graph.mutate!(turn_id: turn_id) do |m|
        user =
          m.create_node(
            node_type: Messages::UserMessage.node_type_key,
            state: DAG::Node::FINISHED,
            lane_id: conversation.chat_lane.id,
            content: "Inspect the file",
            metadata: {},
          )
        agent_node =
          m.create_node(
            node_type: Messages::AgentMessage.node_type_key,
            state: DAG::Node::PENDING,
            lane_id: conversation.chat_lane.id,
            metadata: {},
          )

        m.create_edge(from_node: user, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)
      end
      Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      conversation.reload

      run =
        create_conversation_run!(
          conversation: conversation,
          dag_node_id: agent_node.id,
          agent: agent,
          recognized_deployment: recognized_deployment,
          selected_model_ref: "openai/gpt-5.4",
          effective_public_settings: {},
          effective_agent_config: {},
          effective_policy: {},
          snapshot: {},
        )

      {
        agent: agent,
        deployment: deployment,
        conversation: conversation,
        agent_node: agent_node,
        run: run,
      }
    end
end
