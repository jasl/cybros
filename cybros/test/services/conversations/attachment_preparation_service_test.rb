require "test_helper"
require "tmpdir"

class Conversations::AttachmentPreparationServiceTest < ActiveSupport::TestCase
  setup do
    @fixture_servers = []
  end

  teardown do
    Array(@fixture_servers).each(&:shutdown)
  end

  test "ensure_prepared! persists local workspace refs in upload order and writes a per-turn manifest" do
    workspace_root = Dir.mktmpdir("cybros-attachment-preparation-local-")
    agent = Agents::BootstrapBundledDefaultService.ensure_agent!
    recognized_deployment =
      create_recognized_deployment!(
        agent: agent,
        deployment: agent,
        supported_methods: agent.supported_methods,
        capability_snapshot: agent.capability_snapshot,
      )
    conversation = nil
    user_node = nil
    agent_node = nil

    with_default_agent_workspace_root(workspace_root) do
      without_bootstrap_hooks do
        conversation = create_conversation!(agent: agent)
        conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

        result =
          conversation.append_user_message!(
            content: "",
            attachments: [
              uploaded_fixture("attachment-note.txt", "text/plain"),
              uploaded_fixture("attachment-log.csv", "text/csv"),
            ],
          )
        user_node = result.fetch(:user_node)
        agent_node = result.fetch(:agent_node)
      end

      run_draft =
        create_run_draft!(
          conversation: conversation,
          agent: agent,
          recognized_deployment: recognized_deployment,
          trigger_snapshot: { "dag_node_id" => agent_node.id, "kind" => "user_turn" },
        )

      manifest =
        Conversations::AttachmentPreparationService.ensure_prepared!(
          conversation: conversation,
          source_message_node_id: user_node.id,
          run_draft: run_draft,
        )

      assert_equal [1, 2], manifest.map { |entry| entry.fetch("position") }
      assert_equal ["attachment-note.txt", "attachment-log.csv"], manifest.map { |entry| entry.fetch("filename") }
      assert_equal ["workspace_file", "workspace_file"], manifest.map { |entry| entry.dig("prepared_ref", "kind") }

      expected_paths =
        manifest.map do |entry|
          File.join(
            "attachments",
            user_node.id.to_s,
            format("%02d", entry.fetch("position")) + "-" + File.basename(entry.fetch("filename"), File.extname(entry.fetch("filename"))).gsub(/[^a-zA-Z0-9.\-_]+/, "_") + "__" + entry.fetch("id").to_s.first(8) + File.extname(entry.fetch("filename")),
          )
        end

      assert_equal expected_paths, manifest.map { |entry| entry.dig("prepared_ref", "path") }

      manifest.each do |entry|
        absolute_path = entry.dig("prepared_ref", "absolute_path")
        assert File.exist?(absolute_path), "expected prepared file #{absolute_path} to exist"
      end

      turn_manifest_path = conversation.workspace_root_path.join("attachments", user_node.id.to_s, "manifest.json")
      assert File.exist?(turn_manifest_path), "expected manifest at #{turn_manifest_path}"
    end
  ensure
    FileUtils.remove_entry(workspace_root) if workspace_root.present? && File.exist?(workspace_root)
  end

  test "ensure_prepared! reuses remote refs within the same run draft and from a conversation run snapshot" do
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
    user_node = nil
    agent_node = nil

    without_bootstrap_hooks do
      conversation = create_conversation!(agent: runtime.fetch(:agent))
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      result =
        conversation.append_user_message!(
          content: "",
          attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
        )
      user_node = result.fetch(:user_node)
      agent_node = result.fetch(:agent_node)
    end

    recognized_deployment =
      RecognizedDeployment.recognize!(
        agent: runtime.fetch(:agent),
        deployment: runtime.fetch(:deployment),
        capability_snapshot: runtime.fetch(:deployment).capability_snapshot,
      )
    run_draft =
      create_run_draft!(
        conversation: conversation,
        agent: runtime.fetch(:agent),
        recognized_deployment: recognized_deployment,
        selected_model_ref: "dev/mock-model",
        trigger_snapshot: { "dag_node_id" => agent_node.id, "kind" => "user_turn" },
      )

    first_manifest =
      Conversations::AttachmentPreparationService.ensure_prepared!(
        conversation: conversation,
        source_message_node_id: user_node.id,
        run_draft: run_draft,
      )
    second_manifest =
      Conversations::AttachmentPreparationService.ensure_prepared!(
        conversation: conversation,
        source_message_node_id: user_node.id,
        run_draft: run_draft,
      )

    conversation_run =
      create_conversation_run!(
        conversation: conversation,
        dag_node_id: agent_node.id,
        agent: runtime.fetch(:agent),
        recognized_deployment: recognized_deployment,
        selected_model_ref: "dev/mock-model",
        snapshot: { "draft" => { "id" => run_draft.id } },
      )

    third_manifest =
      Conversations::AttachmentPreparationService.ensure_prepared_for_run!(
        conversation: conversation,
        source_message_node_id: user_node.id,
        conversation_run: conversation_run,
      )

    assert_equal 1, attachment_calls.length
    assert_equal first_manifest, second_manifest
    assert_equal first_manifest, third_manifest
    assert_equal ["attachment_import"], first_manifest.map { |entry| entry.dig("prepared_ref", "kind") }
  end

  private

    def uploaded_fixture(name, content_type)
      Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/#{name}"), content_type)
    end

    def start_fixture_server!(identity_overrides: {}, rpc_overrides: {})
      server =
        Cybros::ProgrammableAgentFixture::Server.new(
          required_bearer: "secret://fixture",
          identity_overrides: identity_overrides,
          rpc_overrides: rpc_overrides,
        ).start
      @fixture_servers << server
      server
    end

    def create_external_runtime!(endpoint_url:)
      program =
        create_agent_record!(
          name: "Attachment Preparation Agent #{SecureRandom.hex(4)}",
          config_namespace: "fixture.attachment.preparation.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: {},
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      location =
        create_execution_location_profile!(
          name: "Attachment preparation host #{SecureRandom.hex(4)}",
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
          name: "Attachment preparation workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/attachment-preparation-workspace-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        create_execution_profile!(
          execution_location: location,
          workspace: workspace,
          name: "Attachment preparation target #{SecureRandom.hex(4)}",
          status: "active",
          sandboxed: true,
        )
      agent = materialize_agent_runtime!(agent: program, execution_profile: target)
      supported_methods = Agents::Protocol::REQUIRED_METHODS + [Agents::Protocol::ATTACHMENT_IMPORT_METHOD]
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
