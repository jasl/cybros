require "test_helper"

class AgentRPC::KernelServices::WorkspaceMemoryTest < ActiveSupport::TestCase
  test "get returns stable not-materialized documents for root conversation and lane scopes" do
    workspace_root = Dir.mktmpdir("cybros-workspace-memory-")
    conversation = create_conversation!(title: "Workspace memory")

    with_default_agent_workspace_root(workspace_root) do
      root_document =
        AgentRPC::KernelServices::WorkspaceMemory.get(
          conversation: conversation,
          lane: conversation.chat_lane,
          scope: "root",
        )
      conversation_document =
        AgentRPC::KernelServices::WorkspaceMemory.get(
          conversation: conversation,
          lane: conversation.chat_lane,
          scope: "conversation",
        )
      lane_document =
        AgentRPC::KernelServices::WorkspaceMemory.get(
          conversation: conversation,
          lane: conversation.chat_lane,
          scope: "lane",
        )

      assert_equal false, root_document.dig("document", "materialized")
      assert_equal false, conversation_document.dig("document", "materialized")
      assert_equal false, lane_document.dig("document", "materialized")
      assert_equal conversation.agent.workspace_root_path.join("MEMORY.md").to_s, root_document.dig("document", "path")
      assert_equal conversation.workspace_root_path.join("MEMORY.md").to_s, conversation_document.dig("document", "path")
      assert_equal conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id).join("MEMORY.md").to_s, lane_document.dig("document", "path")
    end
  ensure
    FileUtils.rm_rf(workspace_root) if workspace_root.present?
  end

  test "put and append lazily materialize missing directories and daily log files" do
    workspace_root = Dir.mktmpdir("cybros-workspace-memory-")
    conversation = create_conversation!(title: "Workspace memory")
    daily_target = "memory/#{Date.current.strftime("%Y-%m-%d")}.md"

    with_default_agent_workspace_root(workspace_root) do
      lane_result =
        AgentRPC::KernelServices::WorkspaceMemory.append!(
          conversation: conversation,
          lane: conversation.chat_lane,
          scope: "lane",
          target: daily_target,
          text: "Lane note",
        )
      conversation_result =
        AgentRPC::KernelServices::WorkspaceMemory.put!(
          conversation: conversation,
          lane: conversation.chat_lane,
          scope: "conversation",
          body: "Conversation note",
        )

      assert_equal true, lane_result.dig("document", "materialized")
      assert_equal "Lane note", conversation.lane_workspace_root_path(lane_id: conversation.chat_lane.id).join(daily_target).read
      assert_equal "Conversation note", conversation.workspace_root_path.join("MEMORY.md").read
      assert_equal true, conversation_result.dig("document", "materialized")
    end
  ensure
    FileUtils.rm_rf(workspace_root) if workspace_root.present?
  end
end
