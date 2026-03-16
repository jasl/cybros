require "test_helper"

class Agents::WorkspaceInitializerTest < ActiveSupport::TestCase
  setup do
    @workspace_root = Dir.mktmpdir("cybros-agent-workspaces-")
  end

  teardown do
    FileUtils.rm_rf(@workspace_root) if @workspace_root.present?
  end

  test "initialize! materializes one agent root shared by many conversations" do
    agent = Agents::BootstrapBundledDefaultService.ensure_agent!
    first_conversation = create_conversation!(agent: agent, title: "First")
    second_conversation = create_conversation!(agent: agent, title: "Second")

    with_default_agent_workspace_root(@workspace_root) do
      first = Agents::WorkspaceInitializer.initialize!(agent: agent)
      second = Agents::WorkspaceInitializer.initialize!(agent: agent)

      first_conversation_workspace = Conversations::WorkspaceInitializer.initialize!(conversation: first_conversation)
      second_conversation_workspace = Conversations::WorkspaceInitializer.initialize!(conversation: second_conversation)

      assert_equal first.fetch(:root_path), second.fetch(:root_path)
      assert_equal first.fetch(:root_path), Pathname.new(first_conversation_workspace.fetch(:conversation_path)).dirname.dirname.to_s
      assert_equal first.fetch(:root_path), Pathname.new(second_conversation_workspace.fetch(:conversation_path)).dirname.dirname.to_s
      assert_equal agent.id, first.fetch(:agent_id)
      assert_equal agent.id, second.fetch(:agent_id)
      assert Dir.exist?(first.fetch(:root_path))
    end
  end

  test "initialize! uses the resolver contract for bundled claw roots" do
    agent = Agents::BootstrapBundledDefaultService.ensure_agent!

    with_default_agent_workspace_root(@workspace_root) do
      workspace = Agents::WorkspaceInitializer.initialize!(agent: agent)

      assert_equal Agents::WorkspacePathResolver.resolve(agent: agent).to_s, workspace.fetch(:root_path)
      assert_equal Pathname.new(@workspace_root).join("bundled", "claw").cleanpath.to_s, workspace.fetch(:root_path)
    end
  end
end
