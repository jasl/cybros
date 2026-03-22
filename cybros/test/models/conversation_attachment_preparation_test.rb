require "test_helper"

class ConversationAttachmentPreparationTest < ActiveSupport::TestCase
  test "enforces uniqueness per attachment and run draft" do
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

    without_bootstrap_hooks do
      conversation = create_conversation!(agent: agent)
      conversation.define_singleton_method(:enqueue_conversation_run!) { |**_kwargs| false }

      result =
        conversation.append_user_message!(
          content: "",
          attachments: [uploaded_fixture("attachment-note.txt", "text/plain")],
        )
      user_node = result.fetch(:user_node)
      agent_node = result.fetch(:agent_node)
    end

    attachment = conversation.conversation_attachments.find_by!(source_message_node_id: user_node.id)
    run_draft =
      create_run_draft!(
        conversation: conversation,
        agent: agent,
        recognized_deployment: recognized_deployment,
        trigger_snapshot: { "dag_node_id" => agent_node.id, "kind" => "user_turn" },
      )

    ConversationAttachmentPreparation.create!(
      conversation_attachment: attachment,
      run_draft: run_draft,
      recognized_deployment: recognized_deployment,
      transfer_mode: "workspace_copy",
      status: "prepared",
      prepared_ref: { "kind" => "workspace_file", "path" => "attachments/example.txt" },
      prepared_at: Time.current,
    )

    duplicate =
      ConversationAttachmentPreparation.new(
        conversation_attachment: attachment,
        run_draft: run_draft,
        recognized_deployment: recognized_deployment,
        transfer_mode: "workspace_copy",
        status: "prepared",
        prepared_ref: { "kind" => "workspace_file", "path" => "attachments/example.txt" },
        prepared_at: Time.current,
      )

    assert_equal false, duplicate.valid?
    assert_includes duplicate.errors[:conversation_attachment_id], "has already been taken"
  end

  private

    def uploaded_fixture(name, content_type)
      Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/#{name}"), content_type)
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
