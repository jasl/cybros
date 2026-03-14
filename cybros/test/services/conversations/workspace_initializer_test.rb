require "test_helper"

class Conversations::WorkspaceInitializerTest < ActiveSupport::TestCase
  setup do
    @workspace_root = Dir.mktmpdir("cybros-conversation-workspaces-")
  end

  teardown do
    FileUtils.rm_rf(@workspace_root) if @workspace_root.present?
  end

  test "initialize! allocates a stable logical workspace once" do
    conversation = create_conversation!

    with_default_agent_workspace_root(@workspace_root) do
      first = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
      second = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)

      conversation.reload

      assert_equal first.fetch(:logical_workspace_key), second.fetch(:logical_workspace_key)
      assert_equal first.fetch(:logical_workspace_root_path), second.fetch(:logical_workspace_root_path)
      assert_equal "conversation-#{conversation.id}", conversation.logical_workspace_key
      assert_equal Pathname.new(@workspace_root).join("conversations", "conversation-#{conversation.id}").cleanpath.to_s, conversation.logical_workspace_root_path
      assert_predicate conversation.logical_workspace_initialized_at, :present?
      assert Dir.exist?(conversation.logical_workspace_root_path)
    end
  end

  test "initialize! sanitizes an existing logical workspace key before creating the path" do
    conversation = create_conversation!
    conversation.update_columns(logical_workspace_key: "..")

    with_default_agent_workspace_root(@workspace_root) do
      workspace = Conversations::WorkspaceInitializer.initialize!(conversation: conversation)

      conversation.reload

      refute_equal "..", conversation.logical_workspace_key
      assert_equal workspace.fetch(:logical_workspace_key), conversation.logical_workspace_key
      assert_equal Pathname.new(@workspace_root).join("conversations", "conversation-#{conversation.id}").cleanpath.to_s, conversation.logical_workspace_root_path
      assert_equal conversation.logical_workspace_root_path, workspace.fetch(:logical_workspace_root_path)
      assert_equal Pathname.new(@workspace_root).join("conversations").cleanpath.to_s, Pathname.new(conversation.logical_workspace_root_path).dirname.to_s
      assert Dir.exist?(conversation.logical_workspace_root_path)
    end
  end
end
