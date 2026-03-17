require "test_helper"
require "digest"

class ConversationAttachmentUploadGateTest < ActionDispatch::IntegrationTest
  setup do
    @fixture_servers = []
  end

  teardown do
    Array(@fixture_servers).each(&:shutdown)
  end

  test "create rejects attachments when the current agent runtime does not support upload" do
    user = sign_in_owner!
    runtime = create_agent_runtime!(supported_methods: Agents::Protocol::REQUIRED_METHODS)
    conversation = create_conversation!(user: user, title: "Chat", agent: runtime.fetch(:agent))

    assert_no_difference -> { ConversationAttachment.count } do
      assert_no_difference -> { DAG::Node.count } do
        post conversation_messages_path(conversation), params: {
          content: "Please inspect this",
          attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
        }
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Selected agent does not support file attachments."
  end

  test "append_user_message! persists ordered attachment rows and snapshots the manifest onto the user message" do
    user = sign_in_owner!
    server =
      start_fixture_server!(
        identity_overrides: {
          "supported_methods" => Agents::Protocol::REQUIRED_METHODS + ["attachments.import"],
        },
      )
    runtime = create_agent_runtime!(supported_methods: Agents::Protocol::REQUIRED_METHODS + ["attachments.import"], endpoint_url: server.rpc_url)
    Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: runtime.fetch(:deployment))
    RecognizedDeployment.recognize!(agent: runtime.fetch(:agent), deployment: runtime.fetch(:deployment))
    conversation = nil
    result = nil

    without_bootstrap_hooks do
      conversation = create_conversation!(user: user, title: "Chat", agent: runtime.fetch(:agent))
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      assert_difference -> { ConversationAttachment.count }, +2 do
        result = conversation.append_user_message!(
          content: "",
          attachments: [
            uploaded_fixture("attachment-note.txt", "text/plain"),
            uploaded_fixture("attachment-log.csv", "text/csv"),
          ],
        )
      end
    end

    user_node = result.fetch(:user_node)
    manifest = user_node.body_input.fetch("attachments")

    assert_equal "", user_node.body_input.fetch("content")
    assert_equal 2, manifest.length
    assert_equal ["attachment-note.txt", "attachment-log.csv"], manifest.map { |entry| entry.fetch("filename") }
    assert_equal [1, 2], manifest.map { |entry| entry.fetch("position") }
    assert_equal Array.new(2, user_node.id.to_s), manifest.map { |entry| entry.fetch("source_message_node_id") }
    assert_equal [Digest::SHA256.file(fixture_path("attachment-note.txt")).hexdigest, Digest::SHA256.file(fixture_path("attachment-log.csv")).hexdigest], manifest.map { |entry| entry.fetch("digest") }

    attachments = conversation.conversation_attachments.where(source_message_node_id: user_node.id).order(:position)
    assert_equal manifest.map { |entry| entry.fetch("id") }, attachments.pluck(:id)
  end

  private

    def sign_in_owner!
      identity =
        Identity.create!(
          email: "admin@example.com",
          password: "Passw0rd",
          password_confirmation: "Passw0rd",
        )
      user = User.create!(identity: identity, role: :owner)

      post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
      assert_redirected_to root_path
      user
    end

    def uploaded_fixture(name, content_type)
      Rack::Test::UploadedFile.new(fixture_path(name), content_type)
    end

    def fixture_path(name)
      Rails.root.join("test/fixtures/files/#{name}")
    end

    def start_fixture_server!(identity_overrides: {})
      server =
        Cybros::ProgrammableAgentFixture::Server.new(
          required_bearer: "secret://fixture",
          identity_overrides: identity_overrides,
        ).start
      @fixture_servers << server
      server
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

    def create_agent_runtime!(supported_methods:, endpoint_url: "https://example.test/rpc")
      program =
        create_agent_record!(
          name: "Attachment Agent #{SecureRandom.hex(4)}",
          config_namespace: "fixture.attachment.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: {},
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      location =
        create_execution_location_profile!(
          name: "Attachment host #{SecureRandom.hex(4)}",
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
          name: "Attachment workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/attachment-workspace-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        create_execution_profile!(
          execution_location: location,
          workspace: workspace,
          name: "Attachment target #{SecureRandom.hex(4)}",
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
          protocol_version: "agent_rpc.v1",
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

      { agent: agent, deployment: deployment }
    end
end
