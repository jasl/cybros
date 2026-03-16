require "test_helper"
require "tmpdir"

class DefaultAgentAttachmentTransferTest < ActiveSupport::TestCase
  test "transfer_attachments materializes conversation attachments into the conversation directory for the bundled claw agent" do
    workspace_root = Dir.mktmpdir("cybros-default-attachments-")
    agent = Agents::BootstrapBundledDefaultService.ensure_agent!
    conversation = nil
    append_result = nil

    assert_equal "claw", agent.bundled_agent_key

    with_default_agent_workspace_root(workspace_root) do
      without_bootstrap_hooks do
        conversation =
          create_conversation!(
            agent: agent,
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
      assert_equal "workspace_copy", metadata.fetch("transfer_mode")
      assert_predicate conversation.reload, :logical_workspace_initialized?
      assert_equal agent.workspace_root_path.to_s, metadata.dig("workspace", "root_path")
      assert_equal conversation.workspace_root_path.to_s, metadata.dig("workspace", "conversation_path")
      assert_equal conversation.workspace_root_path.to_s, metadata.dig("workspace", "cwd")
      assert_equal conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id).to_s, metadata.dig("workspace", "lane_path")

      imports = metadata.fetch("imports")
      assert_equal 2, imports.length
      assert_equal ["workspace_file", "workspace_file"], imports.map { |entry| entry.dig("remote_ref", "kind") }

      first_destination = File.join(metadata.dig("workspace", "conversation_path"), imports.first.dig("remote_ref", "path"))
      second_destination = File.join(metadata.dig("workspace", "conversation_path"), imports.second.dig("remote_ref", "path"))

      assert_equal fixture_content("attachment-note.txt"), File.binread(first_destination)
      assert_equal fixture_content("attachment-log.csv"), File.binread(second_destination)
    end
  ensure
    FileUtils.remove_entry(workspace_root) if workspace_root.present? && File.exist?(workspace_root)
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
