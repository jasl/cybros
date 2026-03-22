require "test_helper"
require_relative "../support/programmable_agent_runtime_test_support"

class AttachmentPromptInjectionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProgrammableAgentRuntimeTestSupport

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "planning and runtime hook payloads include attachment manifests workspace descriptors and multimodal image inputs" do
    captured_params = {}
    llm_payloads = []
    llm_server =
      MockLLMServer.new do |payload|
        llm_payloads << payload.deep_dup
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
        },
      ).start

    with_catalog_yaml(mock_vision_catalog_yaml(base_url: llm_server.base_url)) do
      runtime = create_programmable_runtime!(server: server)
      conversation = runtime.fetch(:conversation)

      result =
        conversation.append_user_message!(
          content: "Inspect these files",
          model_ref: "dev/vision-model",
          attachments: [
            uploaded_fixture("attachment-image.png", "image/png"),
            uploaded_fixture("attachment-log.csv", "text/csv"),
          ],
        )
      user_node = result.fetch(:user_node)
      agent_node = result.fetch(:agent_node)
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

      conversation.reload

      run_claimed_nodes_until_idle!(graph: conversation.root_graph)

      expected_workspace = conversation.workspace_payload(lane_id: agent_node.lane_id)
      prepare_manifest = Array(captured_params.dig(:prepare, "attachment_manifest"))
      finalize_manifest = Array(captured_params.dig(:finalize, "attachment_manifest"))

      assert_equal 2, prepare_manifest.length
      assert_equal prepare_manifest, finalize_manifest
      assert_equal ["attachment-image.png", "attachment-log.csv"], prepare_manifest.map { |entry| entry.fetch("filename") }
      assert_equal ["attachment_import", "attachment_import"], prepare_manifest.map { |entry| entry.fetch("kind") }
      assert_equal ["attachment_import", "attachment_import"], prepare_manifest.map { |entry| entry.dig("prepared_ref", "kind") }
      assert_match %r{/rails/active_storage/representations/proxy/}, prepare_manifest.first.fetch("prompt_image_url")
      assert_equal "image/png", prepare_manifest.first.fetch("prompt_image_media_type")
      assert_nil prepare_manifest.second["prompt_image_url"]
      assert_equal expected_workspace, captured_params.dig(:prepare, "session_context", "workspace")
      assert_equal expected_workspace, captured_params.dig(:prepare, "execution_context", "workspace")
      assert_equal expected_workspace, captured_params.dig(:finalize, "session_context", "workspace")
      assert_equal expected_workspace, captured_params.dig(:finalize, "execution_context", "workspace")

      latest_user_message =
        Array(captured_params.dig(:finalize, "provider_input", "messages")).reverse.find do |message|
          message.is_a?(Hash) && message["role"].to_s == "user"
        end
      content = latest_user_message.fetch("content")
      text_blocks = Array(content).select { |block| block.is_a?(Hash) && block["type"].to_s == "text" }.map { |block| block["text"].to_s }
      image_blocks = Array(content).select { |block| block.is_a?(Hash) && block["type"].to_s == "image" }

      assert_includes text_blocks.join("\n"), "Inspect these files"
      assert_includes text_blocks.join("\n"), "Attachment 1: attachment-image.png (image/png)"
      assert_includes text_blocks.join("\n"), "Attachment 2: attachment-log.csv (text/csv)"
      refute_includes text_blocks.join("\n"), fixture_content("attachment-log.csv")
      assert_equal 1, image_blocks.length
      assert_equal "url", image_blocks.first.fetch("source_type")
      assert_equal "image/png", image_blocks.first.fetch("media_type")
      assert_match %r{/rails/active_storage/representations/proxy/}, image_blocks.first.fetch("url")

      llm_user_message =
        Array(llm_payloads.last&.dig("messages")).reverse.find do |message|
          message.is_a?(Hash) && message["role"].to_s == "user"
        end
      llm_text_blocks =
        Array(llm_user_message&.fetch("content", nil))
          .select { |block| block.is_a?(Hash) && block["type"].to_s == "text" }
          .map { |block| block["text"].to_s }
      llm_image_blocks =
        Array(llm_user_message&.fetch("content", nil))
          .select { |block| block.is_a?(Hash) && block["type"].to_s == "image_url" }

      assert_includes llm_text_blocks.join("\n"), "Inspect these files"
      assert_includes llm_text_blocks.join("\n"), "Attachment 1: attachment-image.png (image/png)"
      assert_includes llm_text_blocks.join("\n"), "Attachment 2: attachment-log.csv (text/csv)"
      refute_includes llm_text_blocks.join("\n"), fixture_content("attachment-log.csv")
      assert_equal 1, llm_image_blocks.length
      assert_match %r{/rails/active_storage/representations/proxy/}, llm_image_blocks.first.dig("image_url", "url")
      assert_equal "succeeded", run.reload.state
    end
  ensure
    llm_server&.shutdown
    server&.shutdown
  end

  test "non-multimodal models keep attachment text but emit no image blocks" do
    captured_params = {}
    llm_payloads = []
    llm_server =
      MockLLMServer.new do |payload|
        llm_payloads << payload.deep_dup
        MockLLMServer.chat_response(content: "llm draft answer")
      end.start
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "before_finalize_output" => lambda do |params, base_result, _identity|
            captured_params[:finalize] = params.deep_dup
            base_result
          end,
        },
      ).start

    with_catalog_yaml(mock_text_only_catalog_yaml(base_url: llm_server.base_url)) do
      runtime = create_programmable_runtime!(server: server)
      conversation = runtime.fetch(:conversation)

      result =
        conversation.append_user_message!(
          content: "Inspect this image",
          model_ref: "dev/text-model",
          attachments: [uploaded_fixture("attachment-image.png", "image/png")],
        )
      agent_node = result.fetch(:agent_node)
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

      run_claimed_nodes_until_idle!(graph: conversation.root_graph)

      latest_user_message =
        Array(captured_params.dig(:finalize, "provider_input", "messages")).reverse.find do |message|
          message.is_a?(Hash) && message["role"].to_s == "user"
        end

      content = Array(latest_user_message.fetch("content"))
      text_blocks = content.select { |block| block.is_a?(Hash) && block["type"].to_s == "text" }.map { |block| block["text"].to_s }
      image_blocks = content.select { |block| block.is_a?(Hash) && block["type"].to_s == "image" }
      llm_user_message =
        Array(llm_payloads.last&.dig("messages")).reverse.find do |message|
          message.is_a?(Hash) && message["role"].to_s == "user"
        end
      llm_image_blocks =
        Array(llm_user_message&.fetch("content", nil))
          .select { |block| block.is_a?(Hash) && block["type"].to_s == "image_url" }

      assert_includes text_blocks.join("\n"), "Attachment 1: attachment-image.png (image/png)"
      assert_equal [], image_blocks
      assert_equal [], llm_image_blocks
      assert_equal "succeeded", run.reload.state
    end
  ensure
    llm_server&.shutdown
    server&.shutdown
  end

  test "invalid image bytes degrade to workspace-only prompt text without image blocks" do
    captured_params = {}
    llm_payloads = []
    llm_server =
      MockLLMServer.new do |payload|
        llm_payloads << payload.deep_dup
        MockLLMServer.chat_response(content: "llm draft answer")
      end.start
    server =
      Cybros::ProgrammableAgentFixture::Server.new(
        required_bearer: "secret://fixture",
        rpc_overrides: {
          "before_finalize_output" => lambda do |params, base_result, _identity|
            captured_params[:finalize] = params.deep_dup
            base_result
          end,
        },
      ).start

    with_catalog_yaml(mock_vision_catalog_yaml(base_url: llm_server.base_url)) do
      runtime = create_programmable_runtime!(server: server)
      conversation = runtime.fetch(:conversation)

      result =
        conversation.append_user_message!(
          content: "Inspect this broken image",
          model_ref: "dev/vision-model",
          attachments: [uploaded_fixture("attachment-note.txt", "image/png", filename: "broken-image.png")],
        )
      agent_node = result.fetch(:agent_node)
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent_node.id)

      run_claimed_nodes_until_idle!(graph: conversation.root_graph)

      latest_user_message =
        Array(captured_params.dig(:finalize, "provider_input", "messages")).reverse.find do |message|
          message.is_a?(Hash) && message["role"].to_s == "user"
        end

      content = Array(latest_user_message.fetch("content"))
      text_blocks = content.select { |block| block.is_a?(Hash) && block["type"].to_s == "text" }.map { |block| block["text"].to_s }
      image_blocks = content.select { |block| block.is_a?(Hash) && block["type"].to_s == "image" }
      llm_user_message =
        Array(llm_payloads.last&.dig("messages")).reverse.find do |message|
          message.is_a?(Hash) && message["role"].to_s == "user"
        end
      llm_image_blocks =
        Array(llm_user_message&.fetch("content", nil))
          .select { |block| block.is_a?(Hash) && block["type"].to_s == "image_url" }

      assert_includes text_blocks.join("\n"), "Attachment 1: broken-image.png (image/png)"
      assert_includes text_blocks.join("\n"), "could not be forwarded to the model as an image"
      assert_equal [], image_blocks
      assert_equal [], llm_image_blocks
      assert_equal "succeeded", run.reload.state
    end
  ensure
    llm_server&.shutdown
    server&.shutdown
  end

  private

    def create_programmable_runtime!(server:)
      user = create_user!
      program =
        create_agent_record!(
          name: "Attachment Prompt Agent #{SecureRandom.hex(4)}",
          config_namespace: "fixture.attachment.prompt.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: {},
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      location =
        create_execution_location_profile!(
          name: "Attachment prompt host #{SecureRandom.hex(4)}",
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
          name: "Attachment prompt workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/attachment-prompt-workspace-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        create_execution_profile!(
          execution_location: location,
          workspace: workspace,
          name: "Attachment prompt target #{SecureRandom.hex(4)}",
          status: "active",
          sandboxed: true,
        )
      agent = materialize_agent_runtime!(agent: program, execution_profile: target)
      fixture_identity = Cybros::ProgrammableAgentFixture.identity
      supported_methods = fixture_identity.fetch("supported_methods")
      deployment =
        create_runtime_binding_record!(
          agent: program,
          transport_kind: "http_jsonrpc",
          endpoint_url: server.rpc_url,
          deployment_bearer_secret_ref: "secret://fixture",
          contract_fingerprint: program.published_contract_fingerprint,
          deployment_fingerprint: fixture_identity.fetch("deployment_fingerprint"),
          status: "active",
          health_status: "healthy",
          protocol_version: fixture_identity.fetch("protocol_version"),
          agent_sdk_version: fixture_identity.fetch("agent_sdk_version"),
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

      conversation =
        create_conversation!(
          user: user,
          title: "Attachment Prompt Chat",
          agent: agent,
        )

      { conversation: conversation, agent: agent, program: program }
    end

    def uploaded_fixture(name, content_type, filename: name)
      Rack::Test::UploadedFile.new(fixture_path(name), content_type, true, original_filename: filename)
    end

    def fixture_path(name)
      Rails.root.join("test/fixtures/files/#{name}")
    end

    def fixture_content(name)
      File.binread(fixture_path(name))
    end

    def mock_vision_catalog_yaml(base_url:)
      <<~YAML
        version: 1
        default_model_ref: "dev/vision-model"
        providers:
          dev:
            display_name: "Dev"
            enabled: true
            adapter_key: "dev"
            base_url: "#{base_url}"
            headers: {}
            requires_credential: false
            wire_api: "chat_completions"
            transport: "http"
            models:
              vision-model:
                display_name: "Vision Mock"
                api_model: "vision-model"
                context_window_tokens: 20000
                capabilities:
                  input: { text: true, image: true }
                  tools: { tool_calling: true }
                  protocol: "chat_completions"
      YAML
    end

    def mock_text_only_catalog_yaml(base_url:)
      <<~YAML
        version: 1
        default_model_ref: "dev/text-model"
        providers:
          dev:
            display_name: "Dev"
            enabled: true
            adapter_key: "dev"
            base_url: "#{base_url}"
            headers: {}
            requires_credential: false
            wire_api: "chat_completions"
            transport: "http"
            models:
              text-model:
                display_name: "Text Mock"
                api_model: "text-model"
                context_window_tokens: 20000
                capabilities:
                  input: { text: true, image: false }
                  tools: { tool_calling: true }
                  protocol: "chat_completions"
      YAML
    end

    def run_claimed_nodes_until_idle!(graph:)
      10.times do
        claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
        return if claimed.empty?

        claimed.each do |node|
          node.update!(claim_after_at: nil) if node.respond_to?(:claim_after_at) && node.claim_after_at.present?
          DAG::Runner.run_node!(node.id)
        end
      end

      flunk "expected graph to become idle"
    end
end
