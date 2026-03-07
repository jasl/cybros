require "test_helper"

class DAG::UserInputCoalescingFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "coalesces fragments into the same logical turn before the assistant becomes claimable" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    travel_to(Time.zone.parse("2026-03-07 10:00:00"))
    begin
      first = conversation.append_user_message!(content: "Hello")
      user_node = first.fetch(:user_node)
      agent_node = first.fetch(:agent_node)

      assert_equal [], DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test").map(&:id)
      assert user_node.metadata["fragments"].is_a?(Array)
      assert_equal ["Hello"], user_node.metadata["fragments"]
      assert_equal "Hello", user_node.body_input["content"]
      assert agent_node.claim_after_at.present?

      travel 0.5.seconds
      merged = conversation.append_user_message!(content: "World")

      assert_equal user_node.id, merged.fetch(:user_node).id
      assert_equal agent_node.id, merged.fetch(:agent_node).id

      user_node.reload
      agent_node.reload

      assert_equal "Hello\nWorld", user_node.body_input["content"]
      assert_equal ["Hello", "World"], user_node.metadata["fragments"]
      assert agent_node.claim_after_at > Time.zone.parse("2026-03-07 10:00:01")

      travel 2.seconds
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [agent_node.id], claimed.map(&:id)
    ensure
      travel_back
    end
  end

  test "queued follow-up fragments collapse into one queued logical turn before that assistant becomes claimable" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = conversation.chat_lane

    running_agent = nil
    graph.mutate!(turn_id: "0194f3c0-0000-7000-8000-00000000c101") do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "u1",
          metadata: {},
        )
      running_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          lane_id: lane.id,
          metadata: {},
        )
      m.create_edge(from_node: user_node, to_node: running_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    travel_to(Time.zone.parse("2026-03-07 11:00:00"))
    begin
      first = conversation.append_user_message!(content: "next")
      queued_user = first.fetch(:user_node)
      queued_agent = first.fetch(:agent_node)

      travel 0.5.seconds
      merged = conversation.append_user_message!(content: "please")

      assert_equal queued_user.id, merged.fetch(:user_node).id
      assert_equal queued_agent.id, merged.fetch(:agent_node).id

      queued_user.reload
      queued_agent.reload

      assert_equal 2, graph.nodes.active.where(lane_id: lane.id, node_type: Messages::UserMessage.node_type_key).count
      assert_equal 2, graph.nodes.active.where(lane_id: lane.id, node_type: Messages::AgentMessage.node_type_key).count
      assert_equal "next\nplease", queued_user.body_input["content"]
      assert_equal ["next", "please"], queued_user.metadata["fragments"]
      assert queued_agent.claim_after_at.present?
      assert_equal [], DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test").map(&:id)
    ensure
      travel_back
    end
  end

  test "queued follow-up fragments still coalesce after the time window while a dependency keeps that turn unclaimable" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = conversation.chat_lane

    running_agent = nil
    graph.mutate!(turn_id: "0194f3c0-0000-7000-8000-00000000c201") do |m|
      user_node =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: lane.id,
          content: "u1",
          metadata: {},
        )
      running_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::RUNNING,
          lane_id: lane.id,
          metadata: {},
        )
      m.create_edge(from_node: user_node, to_node: running_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    travel_to(Time.zone.parse("2026-03-07 12:00:00"))
    begin
      first = conversation.append_user_message!(content: "next")
      queued_user = first.fetch(:user_node)
      queued_agent = first.fetch(:agent_node)
      initial_claim_after_at = queued_agent.claim_after_at
      assert initial_claim_after_at.present?

      travel 2.seconds
      merged = conversation.append_user_message!(content: "still queued")

      assert_equal queued_user.id, merged.fetch(:user_node).id
      assert_equal queued_agent.id, merged.fetch(:agent_node).id

      queued_user.reload
      queued_agent.reload

      assert_equal "next\nstill queued", queued_user.body_input["content"]
      assert_equal ["next", "still queued"], queued_user.metadata["fragments"]
      assert queued_agent.claim_after_at > initial_claim_after_at
      assert_equal [], DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test").map(&:id)
    ensure
      travel_back
    end
  end
end
