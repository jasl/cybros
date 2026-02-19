require "test_helper"

class ConversationContextTest < ActiveSupport::TestCase
  test "context_for returns preview payload by default and context_for_full includes full output" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )

    assert_equal 2000, Messages::AgentMessage.new.preview_max_chars
    long_content = "a" * (Messages::AgentMessage.new.preview_max_chars + 50)
    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => long_content },
      metadata: {}
    )

    graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    preview = conversation.context_for(agent.id)
    agent_preview = preview.find { |node| node.fetch("node_id") == agent.id }

    assert agent_preview.key?("turn_id")
    assert_equal agent.turn_id, agent_preview.fetch("turn_id")
    assert_equal({ "content" => "hi" }, preview.find { |node| node.fetch("node_id") == user.id }.dig("payload", "input"))
    assert agent_preview.dig("payload", "output_preview", "content").length <= Messages::AgentMessage.new.preview_max_chars
    assert_not agent_preview.fetch("payload").key?("output")

    full = conversation.context_for_full(agent.id)
    agent_full = full.find { |node| node.fetch("node_id") == agent.id }

    assert_equal long_content, agent_full.dig("payload", "output", "content")
  end

  test "context_for filters excluded nodes by default but include_excluded:true includes them" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )
    agent1 = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: {},
      metadata: {}
    )
    task = graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "result" => "ok" },
      metadata: {}
    )
    agent2 = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::PENDING,
      metadata: {}
    )

    graph.edges.create!(from_node_id: user.id, to_node_id: agent1.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: agent1.id, to_node_id: task.id, edge_type: DAG::Edge::DEPENDENCY)
    graph.edges.create!(from_node_id: task.id, to_node_id: agent2.id, edge_type: DAG::Edge::SEQUENCE)

    agent1.exclude_from_context!
    task.exclude_from_context!

    filtered = conversation.context_for(agent2.id)
    assert_equal [user.id, agent2.id], filtered.map { |node| node.fetch("node_id") }

    included = conversation.context_for(agent2.id, include_excluded: true)
    assert_equal [user.id, agent1.id, task.id, agent2.id], included.map { |node| node.fetch("node_id") }
  end

  test "context_for always includes target even if excluded or deleted" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )

    agent.exclude_from_context!
    agent.soft_delete!

    context = conversation.context_for(agent.id)
    assert_equal [agent.id], context.map { |node| node.fetch("node_id") }
  end

  test "soft deleted nodes are excluded from context by default" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )
    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::PENDING,
      metadata: {}
    )

    graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)
    user.soft_delete!

    context = conversation.context_for(agent.id)
    ids = context.map { |node| node.fetch("node_id") }

    assert_equal [agent.id], ids
  end

  test "transcript_for hides tool/task nodes and empty agent_message nodes" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "hi" },
      metadata: {}
    )
    agent1 = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: {},
      metadata: {}
    )
    task = graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "result" => "ok" },
      metadata: {}
    )
    agent2 = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::PENDING,
      metadata: {}
    )

    graph.edges.create!(from_node_id: user.id, to_node_id: agent1.id, edge_type: DAG::Edge::SEQUENCE)
    graph.edges.create!(from_node_id: agent1.id, to_node_id: task.id, edge_type: DAG::Edge::DEPENDENCY)
    graph.edges.create!(from_node_id: task.id, to_node_id: agent2.id, edge_type: DAG::Edge::SEQUENCE)

    transcript = conversation.transcript_for(agent2.id)
    assert_equal [user.id, agent2.id], transcript.map { |node| node.fetch("node_id") }

    limited = conversation.transcript_for(agent2.id, limit: 1)
    assert_equal [agent2.id], limited.map { |node| node.fetch("node_id") }
  end

  test "transcript_for excludes deleted target by default but include_deleted:true includes it" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "hello" },
      metadata: {}
    )

    agent.soft_delete!

    assert_equal [], conversation.transcript_for(agent.id)
    assert_equal [agent.id], conversation.transcript_for(agent.id, include_deleted: true).map { |node| node.fetch("node_id") }
  end

  test "transcript_for includes agent_message when transcript_visible metadata is true and injects transcript_preview content" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: {},
      metadata: { "transcript_visible" => true, "transcript_preview" => "(structured)" }
    )

    transcript = conversation.transcript_for(agent.id)

    assert_equal [agent.id], transcript.map { |node| node.fetch("node_id") }
    assert_equal "(structured)", transcript.first.dig("payload", "output_preview", "content")
  end

  test "context_for pins system/developer messages and the most recent summaries across the graph" do
    conversation = Conversation.create!
    graph = conversation.dag_graph

    user = nil
    agent = nil
    system = nil
    developer = nil
    summaries = nil

    graph.mutate! do |m|
      system =
        m.create_node(
          node_type: Messages::SystemMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "sys",
          metadata: {}
        )
      developer =
        m.create_node(
          node_type: Messages::DeveloperMessage.node_type_key,
          state: DAG::Node::FINISHED,
          content: "dev",
          metadata: {}
        )

      base_time = Time.current - 10.minutes
      summaries =
        5.times.map do |i|
          node =
            m.create_node(
              node_type: "summary",
              state: DAG::Node::FINISHED,
              body_output: { "content" => "s#{i}" },
              metadata: {}
            )

          at = base_time + i.seconds
          node.update_columns(created_at: at, updated_at: at, finished_at: at)
          node
        end

      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "hi", metadata: {})
      agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
      m.create_edge(from_node: system, to_node: developer, edge_type: DAG::Edge::SEQUENCE)
      summaries.each do |summary|
        m.create_edge(from_node: summary, to_node: user, edge_type: DAG::Edge::SEQUENCE)
      end
      m.create_edge(from_node: developer, to_node: user, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
    end

    context = graph.context_for(agent.id, limit_turns: 1)
    ids = context.map { |node| node.fetch("node_id") }

    assert_includes ids, system.id
    assert_includes ids, developer.id

    summaries.last(3).each do |summary|
      assert_includes ids, summary.id
    end

    assert_includes ids, user.id
    assert_includes ids, agent.id
  end
end
