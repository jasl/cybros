require "test_helper"

class ExternalAgentAttachmentTransferTest < ActiveSupport::TestCase
  setup do
    @fixture_servers = []
  end

  teardown do
    Array(@fixture_servers).each(&:shutdown)
  end

  test "transfer_attachments sends signed-url descriptors to external agents and records remote refs" do
    attachment_calls = []
    server =
      start_fixture_server!(
        rpc_overrides: {
          "attachments.import" => lambda do |params, base_result, _identity|
            attachment_calls << params.deep_dup
            base_result
          end,
        },
      )
    runtime = create_external_runtime!(endpoint_url: server.rpc_url)
    conversation = nil
    append_result = nil

    without_bootstrap_hooks do
      conversation =
        create_conversation!(
          agent: runtime.fetch(:agent),
        )
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      append_result =
        conversation.append_user_message!(
          content: "",
          attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
        )
    end
    create_conversation_run!(
      conversation: conversation,
      agent_node: append_result.fetch(:agent_node),
      runtime: runtime,
    )

    task =
      create_transfer_task!(
        conversation: conversation,
        turn_id: append_result.fetch(:agent_node).turn_id,
        attachment_ids: conversation.conversation_attachments.order(:position).pluck(:id),
      )

    execution = execute_task!(task)
    tool_result = AgentCore::Resources::Tools::ToolResult.from_h(execution.payload.fetch("result"))
    metadata = tool_result.metadata

    assert_equal false, tool_result.error?
    assert_equal "rpc_import", metadata.fetch("transfer_mode")
    assert_equal "attachment_import", metadata.dig("imports", 0, "remote_ref", "kind")
    assert_equal 1, attachment_calls.length
    descriptor = attachment_calls.first.fetch("attachments").first
    expected_workspace = conversation.workspace_payload
    assert_match %r{/rails/active_storage/blobs/redirect/}, descriptor.fetch("signed_download_url")
    refute descriptor.key?("bytes_base64")
    assert_equal conversation.id.to_s, descriptor.dig("conversation", "id").to_s
    assert_equal expected_workspace.fetch("root_path"), descriptor.dig("workspace", "root_path")
    assert_equal expected_workspace.fetch("conversation_path"), descriptor.dig("workspace", "conversation_path")
    assert_equal expected_workspace.fetch("lane_path"), descriptor.dig("workspace", "lane_path")
    assert_equal expected_workspace.fetch("cwd"), descriptor.dig("workspace", "cwd")
    refute descriptor.fetch("workspace").key?("logical_workspace_key")
  end

  test "transfer_attachments rejects RPC import payloads with foreign or missing attachment ids" do
    server =
      start_fixture_server!(
        rpc_overrides: {
          "attachments.import" => lambda do |params, _base_result, _identity|
            requested = params.fetch("attachments")
            {
              "imports" => [
                {
                  "id" => requested.first.fetch("id"),
                  "remote_ref" => { "kind" => "attachment_import", "token" => "first" },
                },
                {
                  "id" => "foreign-attachment-id",
                  "remote_ref" => { "kind" => "attachment_import", "token" => "foreign" },
                },
              ],
            }
          end,
        },
      )
    runtime = create_external_runtime!(endpoint_url: server.rpc_url)
    conversation = nil
    append_result = nil

    without_bootstrap_hooks do
      conversation =
        create_conversation!(
          agent: runtime.fetch(:agent),
        )
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      append_result =
        conversation.append_user_message!(
          content: "",
          attachments: [
            uploaded_fixture("attachment-note.txt", "text/plain"),
            uploaded_fixture("attachment-log.csv", "text/csv"),
          ],
        )
    end
    create_conversation_run!(
      conversation: conversation,
      agent_node: append_result.fetch(:agent_node),
      runtime: runtime,
    )

    task =
      create_transfer_task!(
        conversation: conversation,
        turn_id: append_result.fetch(:agent_node).turn_id,
        attachment_ids: conversation.conversation_attachments.order(:position).pluck(:id),
      )

    execution = execute_task!(task)
    tool_result = AgentCore::Resources::Tools::ToolResult.from_h(execution.payload.fetch("result"))

    assert_equal true, tool_result.error?
    assert_equal "cybros.conversations.attachment_transfer.rpc_import_payload_invalid", tool_result.metadata.dig("tool_execution", "failure_code")
    assert_equal true, tool_result.metadata.dig("tool_execution", "retryable")
  end

  test "transfer_attachments rejects RPC import payloads with duplicate attachment ids" do
    server =
      start_fixture_server!(
        rpc_overrides: {
          "attachments.import" => lambda do |params, _base_result, _identity|
            requested = params.fetch("attachments")
            duplicated_id = requested.first.fetch("id")
            {
              "imports" => [
                {
                  "id" => duplicated_id,
                  "remote_ref" => { "kind" => "attachment_import", "token" => "one" },
                },
                {
                  "id" => duplicated_id,
                  "remote_ref" => { "kind" => "attachment_import", "token" => "two" },
                },
              ],
            }
          end,
        },
      )
    runtime = create_external_runtime!(endpoint_url: server.rpc_url)
    conversation = nil
    append_result = nil

    without_bootstrap_hooks do
      conversation =
        create_conversation!(
          agent: runtime.fetch(:agent),
        )
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      append_result =
        conversation.append_user_message!(
          content: "",
          attachments: [
            uploaded_fixture("attachment-note.txt", "text/plain"),
            uploaded_fixture("attachment-log.csv", "text/csv"),
          ],
        )
    end
    create_conversation_run!(
      conversation: conversation,
      agent_node: append_result.fetch(:agent_node),
      runtime: runtime,
    )

    task =
      create_transfer_task!(
        conversation: conversation,
        turn_id: append_result.fetch(:agent_node).turn_id,
        attachment_ids: conversation.conversation_attachments.order(:position).pluck(:id),
      )

    execution = execute_task!(task)
    tool_result = AgentCore::Resources::Tools::ToolResult.from_h(execution.payload.fetch("result"))

    assert_equal true, tool_result.error?
    assert_equal "cybros.conversations.attachment_transfer.rpc_import_payload_invalid", tool_result.metadata.dig("tool_execution", "failure_code")
    assert_equal true, tool_result.metadata.dig("tool_execution", "retryable")
  end

  test "transfer_attachments rejects duplicate requested attachment ids before RPC import begins" do
    attachment_calls = []
    server =
      start_fixture_server!(
        rpc_overrides: {
          "attachments.import" => lambda do |params, base_result, _identity|
            attachment_calls << params.deep_dup
            base_result
          end,
        },
      )
    runtime = create_external_runtime!(endpoint_url: server.rpc_url)
    conversation = nil
    append_result = nil

    without_bootstrap_hooks do
      conversation =
        create_conversation!(
          agent: runtime.fetch(:agent),
        )
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      append_result =
        conversation.append_user_message!(
          content: "",
          attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
        )
    end
    create_conversation_run!(
      conversation: conversation,
      agent_node: append_result.fetch(:agent_node),
      runtime: runtime,
    )

    attachment_id = conversation.conversation_attachments.order(:position).pick(:id)
    task =
      create_transfer_task!(
        conversation: conversation,
        turn_id: append_result.fetch(:agent_node).turn_id,
        attachment_ids: [attachment_id, attachment_id],
      )

    execution = execute_task!(task)
    tool_result = AgentCore::Resources::Tools::ToolResult.from_h(execution.payload.fetch("result"))

    assert_equal true, tool_result.error?
    assert_equal "cybros.conversations.attachment_transfer.duplicate_attachment_ids", tool_result.metadata.dig("tool_execution", "failure_code")
    assert_equal false, tool_result.metadata.dig("tool_execution", "retryable")
    assert_equal [], attachment_calls
  end

  test "transfer_attachments preserves requested attachment order for rpc imports" do
    attachment_calls = []
    server =
      start_fixture_server!(
        rpc_overrides: {
          "attachments.import" => lambda do |params, base_result, _identity|
            attachment_calls << params.deep_dup
            base_result
          end,
        },
      )
    runtime = create_external_runtime!(endpoint_url: server.rpc_url)
    conversation = nil
    append_result = nil

    without_bootstrap_hooks do
      conversation =
        create_conversation!(
          agent: runtime.fetch(:agent),
        )
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      append_result =
        conversation.append_user_message!(
          content: "",
          attachments: [
            uploaded_fixture("attachment-note.txt", "text/plain"),
            uploaded_fixture("attachment-log.csv", "text/csv"),
          ],
        )
    end
    create_conversation_run!(
      conversation: conversation,
      agent_node: append_result.fetch(:agent_node),
      runtime: runtime,
    )

    requested_attachment_ids = conversation.conversation_attachments.order(:position).pluck(:id).reverse
    task =
      create_transfer_task!(
        conversation: conversation,
        turn_id: append_result.fetch(:agent_node).turn_id,
        attachment_ids: requested_attachment_ids,
      )

    execution = execute_task!(task)
    tool_result = AgentCore::Resources::Tools::ToolResult.from_h(execution.payload.fetch("result"))

    assert_equal false, tool_result.error?
    assert_equal requested_attachment_ids.map(&:to_s), attachment_calls.first.fetch("attachments").map { |entry| entry.fetch("id").to_s }
    assert_equal requested_attachment_ids.map(&:to_s), tool_result.metadata.fetch("imports").map { |entry| entry.fetch("id").to_s }
  end

  test "transfer_attachments leaves the source attachment intact and returns a retriable error when external import fails" do
    server =
      start_fixture_server!(
        rpc_overrides: {
          "attachments.import" => lambda do |_params, _base_result, _identity|
            raise "fixture transfer failed"
          end,
        },
      )
    runtime = create_external_runtime!(endpoint_url: server.rpc_url)
    conversation = nil
    append_result = nil

    without_bootstrap_hooks do
      conversation =
        create_conversation!(
          agent: runtime.fetch(:agent),
        )
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      append_result =
        conversation.append_user_message!(
          content: "",
          attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
        )
    end
    create_conversation_run!(
      conversation: conversation,
      agent_node: append_result.fetch(:agent_node),
      runtime: runtime,
    )

    attachment = conversation.conversation_attachments.order(:position).first
    task =
      create_transfer_task!(
        conversation: conversation,
        turn_id: append_result.fetch(:agent_node).turn_id,
        attachment_ids: [attachment.id],
      )

    execution = execute_task!(task)
    tool_result = AgentCore::Resources::Tools::ToolResult.from_h(execution.payload.fetch("result"))

    assert_equal true, tool_result.error?
    assert_equal true, tool_result.metadata.dig("tool_execution", "retryable")
    assert_predicate attachment.reload.file, :attached?
    assert_equal fixture_content("attachment-note.txt"), attachment.file.download
  end

  test "transfer_attachments fails safe when the agent runtime has changed since the turn pinning" do
    pinned_calls = []
    live_calls = []
    pinned_server =
      start_fixture_server!(
        rpc_overrides: {
          "attachments.import" => lambda do |params, base_result, _identity|
            pinned_calls << params.deep_dup
            base_result
          end,
        },
      )
    live_server =
      start_fixture_server!(
        rpc_overrides: {
          "attachments.import" => lambda do |params, base_result, _identity|
            live_calls << params.deep_dup
            base_result
          end,
        },
      )
    runtime = create_external_runtime!(endpoint_url: pinned_server.rpc_url)
    conversation = nil
    append_result = nil

    without_bootstrap_hooks do
      conversation =
        create_conversation!(
          agent: runtime.fetch(:agent),
        )
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      append_result =
        conversation.append_user_message!(
          content: "",
          attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
        )
    end
    create_conversation_run!(
      conversation: conversation,
      agent_node: append_result.fetch(:agent_node),
      runtime: runtime,
    )

    replacement =
      begin
        runtime.fetch(:deployment).update!(status: "inactive")
        create_additional_deployment!(
          agent: runtime.fetch(:agent),
          program: runtime.fetch(:program),
          endpoint_url: live_server.rpc_url,
          supported_methods: Agents::Protocol::REQUIRED_METHODS + [Agents::Protocol::ATTACHMENT_IMPORT_METHOD],
        )
      end

    assert_equal replacement.deployment_fingerprint, runtime.fetch(:agent).reload.active_runtime_binding.deployment_fingerprint

    task =
      create_transfer_task!(
        conversation: conversation,
        turn_id: append_result.fetch(:agent_node).turn_id,
        attachment_ids: conversation.conversation_attachments.order(:position).pluck(:id),
      )

    execution = execute_task!(task)
    tool_result = AgentCore::Resources::Tools::ToolResult.from_h(execution.payload.fetch("result"))

    assert_equal true, tool_result.error?
    assert_equal "cybros.conversations.attachment_transfer.recognized_deployment_drift", tool_result.metadata.dig("tool_execution", "failure_code")
    assert_equal false, tool_result.metadata.dig("tool_execution", "retryable")
    assert_empty pinned_calls
    assert_empty live_calls
  end

  private

    def uploaded_fixture(name, content_type)
      Rack::Test::UploadedFile.new(fixture_path(name), content_type)
    end

    def fixture_path(name)
      Rails.root.join("test/fixtures/files/#{name}")
    end

    def fixture_content(name)
      File.binread(fixture_path(name))
    end

    def start_fixture_server!(rpc_overrides: {})
      server =
        Cybros::ProgrammableAgentFixture::Server.new(
          required_bearer: "secret://fixture",
          rpc_overrides: rpc_overrides,
        ).start
      @fixture_servers << server
      server
    end

    def create_external_runtime!(endpoint_url:)
      supported_methods = Agents::Protocol::REQUIRED_METHODS + [Agents::Protocol::ATTACHMENT_IMPORT_METHOD]
      program =
        create_agent_record!(
          name: "External Attachment Agent #{SecureRandom.hex(4)}",
          config_namespace: "fixture.external.attachment.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: {},
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      location =
        create_execution_location_profile!(
          name: "External attachment host #{SecureRandom.hex(4)}",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      workspace =
        create_workspace_profile!(
          execution_location: location,
          name: "External attachment workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/external-attachment-workspace-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        create_execution_profile!(
          execution_location: location,
          workspace: workspace,
          name: "External attachment target #{SecureRandom.hex(4)}",
          status: "active",
          sandboxed: true,
        )
      agent = materialize_agent_runtime!(agent: program, execution_profile: target)
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: endpoint_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: "deployment:#{program.id}",
          status: "active",
          health_status: "healthy",
          protocol_version: Agents::Protocol::SUPPORTED_PROTOCOL_VERSION,
          supported_methods: supported_methods,
          manifest_snapshot: {},
          schema_snapshot: {},
          capability_snapshot: {
            "agent_capabilities_version" => "fixture-agent-capabilities:v1",
            "observed_runtime_identity" => {
              "supported_methods" => supported_methods,
            },
          },
          inspection_details: {},
          activated_at: Time.current.change(usec: 0),
        )
      sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)

      { agent: agent, deployment: deployment, program: program }
    end

    def create_additional_deployment!(agent:, program:, endpoint_url:, supported_methods:)
      create_runtime_binding_record!(
        agent: agent,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "deployment:#{program.id}:#{SecureRandom.hex(4)}",
        status: "active",
        health_status: "healthy",
        protocol_version: Agents::Protocol::SUPPORTED_PROTOCOL_VERSION,
        supported_methods: supported_methods,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {
          "agent_capabilities_version" => "fixture-agent-capabilities:v1",
          "observed_runtime_identity" => {
            "supported_methods" => supported_methods,
          },
        },
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      ).tap do |deployment|
        sync_agent_runtime_from_binding!(agent: agent, deployment: deployment)
      end
    end

    def create_conversation_run!(conversation:, agent_node:, runtime:)
      recognized_deployment =
        RecognizedDeployment.recognize!(
          agent: runtime.fetch(:agent),
          deployment: runtime.fetch(:deployment),
          capability_snapshot: runtime.fetch(:deployment).capability_snapshot,
        )

      ConversationRun.create!(
        build_conversation_run_attributes(
          conversation: conversation,
          dag_node_id: agent_node.id,
          agent: runtime.fetch(:agent),
          recognized_deployment: recognized_deployment,
          state: "queued",
          queued_at: Time.current.change(usec: 0),
          initiated_by_user: conversation.user,
          effective_permission_mode: "default",
          selected_model_ref: "dev/mock-model",
          effective_public_settings: {},
          effective_agent_config: {},
          agent_config_schema_fingerprint: runtime.fetch(:program).config_schema_fingerprint,
          effective_policy: {},
          runtime_governors: runtime_governors_snapshot(agent: runtime.fetch(:agent), selected_model_ref: "dev/mock-model"),
          snapshot: {},
        ),
      )
    end

    def create_transfer_task!(conversation:, turn_id:, attachment_ids:)
      conversation.root_graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::RUNNING,
        lane_id: conversation.chat_lane.id,
        turn_id: turn_id,
        metadata: {},
        body_input: {
          "name" => "transfer_attachments",
          "requested_name" => "transfer_attachments",
          "tool_call_id" => "tc_transfer_#{SecureRandom.hex(4)}",
          "arguments" => { "attachment_ids" => attachment_ids },
          "arguments_summary" => JSON.generate({ attachment_ids: attachment_ids }),
        },
      )
    end

    def execute_task!(task)
      registry = Cybros::AgentRuntimeResolver.send(:build_tools_registry)
      runtime =
        AgentCore::DAG::Runtime.new(
          provider: Struct.new(:name).new("test-provider"),
          model: "dev/mock-model",
          tools_registry: registry,
          tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
          llm_options: {},
          instrumenter: AgentCore::Observability::NullInstrumenter.new,
        )

      previous = AgentCore::DAG.runtime_resolver
      AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }
      AgentCore::DAG::Executors::TaskExecutor.new.execute(node: task, context: nil, stream: nil)
    ensure
      AgentCore::DAG.runtime_resolver = previous
    end

    def without_bootstrap_hooks(&block)
      singleton = Conversations::BootstrapHookDispatcher.singleton_class
      original_created = singleton.instance_method(:dispatch_created!)
      original_lane_first_user_message = singleton.instance_method(:dispatch_lane_first_user_message!)

      singleton.send(:define_method, :dispatch_created!) { |**_kwargs| nil }
      singleton.send(:define_method, :dispatch_lane_first_user_message!) { |**_kwargs| nil }

      yield
    ensure
      singleton.send(:define_method, :dispatch_created!, original_created)
      singleton.send(:define_method, :dispatch_lane_first_user_message!, original_lane_first_user_message)
    end
end
