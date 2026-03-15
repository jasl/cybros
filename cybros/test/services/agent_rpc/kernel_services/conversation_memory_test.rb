require "test_helper"

class AgentRPC::KernelServices::ConversationMemoryTest < ActiveSupport::TestCase
  test "get put and append store a conversation-scoped document on the root conversation" do
    root, branch = create_branch_pair!

    assert_equal "", AgentRPC::KernelServices::ConversationMemory.get(conversation: root).dig("document", "body")

    put_result =
      AgentRPC::KernelServices::ConversationMemory.put!(
        conversation: root,
        body: "Remember alpha",
      )

    assert_equal "conversation_memory", put_result.dig("document", "kind")
    assert_equal "Remember alpha", put_result.dig("document", "body")
    assert_equal "Remember alpha", AgentRPC::KernelServices::ConversationMemory.get(conversation: branch).dig("document", "body")

    append_result =
      AgentRPC::KernelServices::ConversationMemory.append!(
        conversation: branch,
        text: "\nRemember beta",
      )

    assert_equal "Remember alpha\nRemember beta", append_result.dig("document", "body")
    assert_nil branch.chat_lane.lane_kv_entries.find_by(key: AgentRPC::KernelServices::ConversationMemory::MEMORY_KEY)
    assert_equal(
      "Remember alpha\nRemember beta",
      root.chat_lane.lane_kv_entries.find_by(key: AgentRPC::KernelServices::ConversationMemory::MEMORY_KEY).value.fetch("body"),
    )
  end

  test "append initializes an empty conversation memory document" do
    conversation = create_conversation!(title: "Root")

    appended =
      AgentRPC::KernelServices::ConversationMemory.append!(
        conversation: conversation,
        text: "Remember alpha",
      )

    assert_equal "Remember alpha", appended.dig("document", "body")
    assert_equal "Remember alpha", AgentRPC::KernelServices::ConversationMemory.get(conversation: conversation).dig("document", "body")
  end

  test "callback dispatcher supports conversation_run scoped memory mutations with idempotent replay" do
    conversation = create_conversation!(title: "Root")
    result = conversation.append_user_message!(content: "Remember this")
    agent_node = result.fetch(:agent_node)
    run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: agent_node.id)
    deployment = conversation.agent.active_runtime_binding

    opened =
      AgentRPC::SessionAuthorizer.open!(
        deployment: deployment,
        conversation: conversation,
        scope_type: "conversation_run",
        scope_id: run.id,
        allowed_methods: %w[conversation.memory.get conversation.memory.put conversation.memory.append],
      )
    invocation =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: conversation.agent,
        recognized_deployment: opened.fetch(:recognized_deployment),
        deployment: deployment,
        conversation: conversation,
        scope_type: "conversation_run",
        scope_id: run.id,
        method_name: "tool.execute",
        invocation_id: "conversation-run-memory",
        request_payload: { "logical_tool_name" => "memory_store" },
      ).fetch(:invocation)
    opened.fetch(:session).update!(agent_rpc_invocation: invocation)

    first =
      AgentRPC::CallbackDispatcher.call!(
        bearer: opened.fetch(:session_bearer),
        method_name: "conversation.memory.put",
        scope_type: "conversation_run",
        scope_id: run.id,
        payload: {
          "body" => "Root note",
          "operation_id" => "op-put",
        },
      )

    replay =
      AgentRPC::CallbackDispatcher.call!(
        bearer: opened.fetch(:session_bearer),
        method_name: "conversation.memory.put",
        scope_type: "conversation_run",
        scope_id: run.id,
        payload: {
          "body" => "Root note",
          "operation_id" => "op-put",
        },
      )

    appended =
      AgentRPC::CallbackDispatcher.call!(
        bearer: opened.fetch(:session_bearer),
        method_name: "conversation.memory.append",
        scope_type: "conversation_run",
        scope_id: run.id,
        payload: {
          "text" => "\nBranch note",
          "operation_id" => "op-append",
        },
      )

    appended_replay =
      AgentRPC::CallbackDispatcher.call!(
        bearer: opened.fetch(:session_bearer),
        method_name: "conversation.memory.append",
        scope_type: "conversation_run",
        scope_id: run.id,
        payload: {
          "text" => "\nBranch note",
          "operation_id" => "op-append",
        },
      )

    fetched =
      AgentRPC::CallbackDispatcher.call!(
        bearer: opened.fetch(:session_bearer),
        method_name: "conversation.memory.get",
        scope_type: "conversation_run",
        scope_id: run.id,
        payload: {},
      )

    assert_equal "Root note", first.dig("document", "body")
    assert_equal first, replay
    assert_equal "Root note\nBranch note", appended.dig("document", "body")
    assert_equal appended, appended_replay
    assert_equal "Root note\nBranch note", fetched.dig("document", "body")
    assert_equal 2, AgentRPCOperationReceipt.where(agent_rpc_invocation: invocation).count
  end

  test "callback dispatcher append initializes empty conversation memory for conversation_run scope" do
    conversation = create_conversation!(title: "Root")
    result = conversation.append_user_message!(content: "Remember this")
    agent_node = result.fetch(:agent_node)
    run = ConversationRun.find_by!(conversation_id: conversation.id, dag_node_id: agent_node.id)
    deployment = conversation.agent.active_runtime_binding

    opened =
      AgentRPC::SessionAuthorizer.open!(
        deployment: deployment,
        conversation: conversation,
        scope_type: "conversation_run",
        scope_id: run.id,
        allowed_methods: %w[conversation.memory.get conversation.memory.append],
      )
    invocation =
      AgentRPC::InvocationStore.start_or_replay!(
        agent: conversation.agent,
        recognized_deployment: opened.fetch(:recognized_deployment),
        deployment: deployment,
        conversation: conversation,
        scope_type: "conversation_run",
        scope_id: run.id,
        method_name: "tool.execute",
        invocation_id: "conversation-run-memory-empty-append",
        request_payload: { "logical_tool_name" => "memory_store" },
      ).fetch(:invocation)
    opened.fetch(:session).update!(agent_rpc_invocation: invocation)

    appended =
      AgentRPC::CallbackDispatcher.call!(
        bearer: opened.fetch(:session_bearer),
        method_name: "conversation.memory.append",
        scope_type: "conversation_run",
        scope_id: run.id,
        payload: {
          "text" => "Root note",
          "operation_id" => "op-append-empty",
        },
      )

    replay =
      AgentRPC::CallbackDispatcher.call!(
        bearer: opened.fetch(:session_bearer),
        method_name: "conversation.memory.append",
        scope_type: "conversation_run",
        scope_id: run.id,
        payload: {
          "text" => "Root note",
          "operation_id" => "op-append-empty",
        },
      )

    assert_equal "Root note", appended.dig("document", "body")
    assert_equal appended, replay
    assert_equal "Root note", AgentRPC::KernelServices::ConversationMemory.get(conversation: conversation).dig("document", "body")
  end

  private

    def create_branch_pair!
      root = create_conversation!(title: "Root")
      root_turn = root.append_user_message!(content: "Root turn")
      root_agent = root_turn.fetch(:agent_node)
      root_agent.mark_running!
      root_agent.mark_finished!(content: "Root reply")

      branch = root.create_child!(from_node_id: root_agent.id, kind: "branch", title: "Branch", user_content: "What if?")

      [root, branch]
    end
end
