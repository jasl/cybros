require "test_helper"

class BootstrapToolsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "cybros_bootstrap_state applies settings, config, kv, and prompt-buffer changes" do
    conversation = nil

    perform_enqueued_jobs do
      conversation = create_conversation!(title: "Conversation")
    end

    lane = conversation.chat_lane
    entry_id = SecureRandom.uuid

    task =
      enqueue_bootstrap_task!(
        conversation: conversation,
        tool_name: "cybros_bootstrap_state",
        arguments: {
          "conversation_id" => conversation.id,
          "lane_id" => lane.id,
          "public_settings_patch" => { "tone" => "concise" },
          "agent_config_patch" => { "mode" => "review" },
          "kv_ops" => [
            { "op" => "set", "key" => "bootstrap.status", "value" => { "ready" => true } },
          ],
          "prompt_buffer_ops" => [
            {
              "op" => "put",
              "entry" => {
                "id" => entry_id,
                "buffer_name" => "system",
                "seq" => 10,
                "kind" => "note",
                "content" => "Bootstrapped system note",
                "priority" => 100,
                "estimated_tokens" => 5,
                "metadata" => { "source" => "bootstrap_test" },
              },
            },
          ],
        },
      )

    perform_enqueued_jobs do
      conversation.root_graph.kick!
    end

    assert_equal DAG::Node::FINISHED, task.reload.state
    assert_equal "concise", conversation.reload.public_settings["tone"]
    assert_equal "review", conversation.selected_agent_config["mode"]
    assert_equal({ "ready" => true }, lane.lane_kv_entries.find_by!(key: "bootstrap.status").value)

    entry = lane.lane_prompt_buffer_entries.find(entry_id)
    assert_equal "system", entry.buffer_name
    assert_equal "Bootstrapped system note", entry.content
  end

  test "cybros_bootstrap_state fails atomically on invalid payloads" do
    conversation = nil

    perform_enqueued_jobs do
      conversation = create_conversation!(title: "Conversation")
    end

    lane = conversation.chat_lane

    task =
      enqueue_bootstrap_task!(
        conversation: conversation,
        tool_name: "cybros_bootstrap_state",
        arguments: {
          "conversation_id" => conversation.id,
          "lane_id" => lane.id,
          "public_settings_patch" => { "tone" => "concise" },
          "prompt_buffer_ops" => [
            {
              "op" => "put",
              "entry" => {
                "buffer_name" => "system",
                "seq" => 10,
                "kind" => "note",
                "content" => "Missing id should fail",
                "priority" => 100,
                "estimated_tokens" => 5,
                "metadata" => {},
              },
            },
          ],
        },
      )

    perform_enqueued_jobs do
      conversation.root_graph.kick!
    end

    assert_equal DAG::Node::FINISHED, task.reload.state
    assert_equal true, AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result")).error?
    assert_equal({}, conversation.reload.public_settings)
    assert_equal({}, conversation.selected_agent_config)
    assert_equal 0, lane.lane_kv_entries.count
    assert_equal 0, lane.lane_prompt_buffer_entries.where(buffer_name: "system").count
  end

  private

    def enqueue_bootstrap_task!(conversation:, tool_name:, arguments:)
      graph = conversation.root_graph
      lane = conversation.chat_lane
      turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
      anchor = conversation.chat_head_leaf
      task = nil

      graph.mutate!(turn_id: turn_id) do |m|
        task =
          m.create_node(
            node_type: Messages::Task.node_type_key,
            state: DAG::Node::PENDING,
            lane_id: lane.id,
            body_input: {
              "tool_call_id" => "bootstrap-test:#{tool_name}:#{SecureRandom.hex(4)}",
              "name" => tool_name,
              "requested_name" => tool_name,
              "arguments" => arguments,
              "arguments_summary" => arguments.to_json,
            },
            metadata: { "generated_by" => "bootstrap_tools_test" },
          )

        m.create_edge(from_node: anchor, to_node: task, edge_type: DAG::Edge::SEQUENCE) if anchor.present?
      end

      task
    end
end
