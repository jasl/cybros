require "test_helper"

class DAG::LargeGraphExtremesTest < ActiveSupport::TestCase
  test "transcript_page and context_for handle 1000-turn linear chat without loading full graph" do
    conversation = Conversation.create!
    graph = conversation.dag_graph
    subgraph = graph.main_subgraph

    turns = 1000
    base_time = Time.current - turns.seconds
    now = Time.current

    turn_rows = []
    body_rows = []
    node_rows = []
    edge_rows = []

    turn_ids = []
    agent_node_ids = []

    turns.times do |i|
      turn_id = stable_uuid(kind: 0x7001, n: i)
      turn_ids << turn_id

      user_body_id = stable_uuid(kind: 0x7002, n: i * 2)
      agent_body_id = stable_uuid(kind: 0x7003, n: (i * 2) + 1)
      user_node_id = stable_uuid(kind: 0x7004, n: i * 2)
      agent_node_id = stable_uuid(kind: 0x7004, n: (i * 2) + 1)

      agent_node_ids << agent_node_id

      at = base_time + i.seconds

      turn_rows << {
        id: turn_id,
        graph_id: graph.id,
        subgraph_id: subgraph.id,
        anchored_seq: i + 1,
        anchor_node_id: user_node_id,
        anchor_created_at: at,
        anchor_node_id_including_deleted: user_node_id,
        anchor_created_at_including_deleted: at,
        metadata: {},
        created_at: at,
        updated_at: at,
      }

      body_rows << {
        id: user_body_id,
        type: "Messages::UserMessage",
        input: { "content" => "u#{i}" },
        output: {},
        output_preview: {},
        created_at: at,
        updated_at: at,
      }
      body_rows << {
        id: agent_body_id,
        type: "Messages::AgentMessage",
        input: {},
        output: { "content" => "a#{i}" },
        output_preview: { "content" => "a#{i}" },
        created_at: at,
        updated_at: at,
      }

      node_rows << {
        id: user_node_id,
        graph_id: graph.id,
        subgraph_id: subgraph.id,
        node_type: Messages::UserMessage.node_type_key,
        state: DAG::Node::FINISHED,
        metadata: {},
        turn_id: turn_id,
        body_id: user_body_id,
        created_at: at,
        updated_at: at,
        finished_at: at,
      }
      node_rows << {
        id: agent_node_id,
        graph_id: graph.id,
        subgraph_id: subgraph.id,
        node_type: Messages::AgentMessage.node_type_key,
        state: DAG::Node::FINISHED,
        metadata: {},
        turn_id: turn_id,
        body_id: agent_body_id,
        created_at: at + 1.second,
        updated_at: at + 1.second,
        finished_at: at + 1.second,
      }

      edge_rows << {
        graph_id: graph.id,
        from_node_id: user_node_id,
        to_node_id: agent_node_id,
        edge_type: DAG::Edge::SEQUENCE,
        metadata: {},
        created_at: now,
        updated_at: now,
      }

      if i.positive?
        edge_rows << {
          graph_id: graph.id,
          from_node_id: agent_node_ids[i - 1],
          to_node_id: user_node_id,
          edge_type: DAG::Edge::SEQUENCE,
          metadata: {},
          created_at: now,
          updated_at: now,
        }
      end
    end

    DAG::Turn.insert_all!(turn_rows)
    DAG::NodeBody.insert_all!(body_rows)
    DAG::Node.insert_all!(node_rows)
    DAG::Edge.insert_all!(edge_rows)

    subgraph.update!(next_anchored_seq: turns)

    page = subgraph.transcript_page(limit_turns: 20)
    assert_equal turn_ids.last(20), page.fetch("turn_ids")
    assert_equal 40, page.fetch("transcript").length

    last_agent_id = agent_node_ids.last
    default_turns = DAG::ContextWindowAssembly::DEFAULT_CONTEXT_TURNS

    context = graph.context_for(last_agent_id)
    assert_equal default_turns * 2, context.length

    closure = graph.context_closure_for(last_agent_id)
    assert_equal turns * 2, closure.length

    transcript = graph.transcript_for(last_agent_id)
    assert_equal default_turns * 2, transcript.length

    transcript_closure = graph.transcript_closure_for(last_agent_id)
    assert_equal turns * 2, transcript_closure.length
  end

  private

    def stable_uuid(kind:, n:)
      kind = Integer(kind)
      n = Integer(n)
      raise ArgumentError, "kind must be 0..0xffff" unless kind.between?(0, 0xffff)
      raise ArgumentError, "n must be >= 0" if n.negative?

      format("00000000-0000-7000-%<kind>04x-%<n>012x", kind: kind, n: n)
    end
end
