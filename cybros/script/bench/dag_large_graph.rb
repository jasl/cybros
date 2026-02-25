require "benchmark"

def ms(duration)
  (duration * 1000).round(1)
end

def measure(label)
  duration = Benchmark.realtime { yield }
  puts format("%<label>s: %<ms>.1fms", label: label, ms: ms(duration))
end

def stable_uuid(kind:, n:)
  kind = Integer(kind)
  n = Integer(n)
  raise ArgumentError, "kind must be 0..0xffff" unless kind.between?(0, 0xffff)
  raise ArgumentError, "n must be >= 0" if n.negative?

  format("00000000-0000-7000-%<kind>04x-%<n>012x", kind: kind, n: n)
end

turns = Integer(ENV.fetch("TURNS", "10000"))
batch_turns = Integer(ENV.fetch("BATCH_TURNS", "500"))

puts "DAG large-graph benchmark"
puts "Rails.env=#{Rails.env}"
puts "TURNS=#{turns} (user+agent per turn)"
puts "BATCH_TURNS=#{batch_turns}"

conversation = Conversation.create!(title: "bench-large-graph")
graph = conversation.dag_graph
lane = graph.main_lane

base_time = Time.current - turns.seconds
now = Time.current

previous_agent_node_id = nil
last_agent_node_id = nil

measure("setup_insert") do
  0.step(turns - 1, batch_turns) do |start_i|
    end_i = [start_i + batch_turns, turns].min

    turn_rows = []
    body_rows = []
    node_rows = []
    edge_rows = []

    (start_i...end_i).each do |i|
      turn_id = stable_uuid(kind: 0x7001, n: i)

      user_body_id = stable_uuid(kind: 0x7002, n: i * 2)
      agent_body_id = stable_uuid(kind: 0x7003, n: (i * 2) + 1)
      user_node_id = stable_uuid(kind: 0x7004, n: i * 2)
      agent_node_id = stable_uuid(kind: 0x7004, n: (i * 2) + 1)

      last_agent_node_id = agent_node_id

      at = base_time + i.seconds

      turn_rows << {
        id: turn_id,
        graph_id: graph.id,
        lane_id: lane.id,
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
        lane_id: lane.id,
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
        lane_id: lane.id,
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

      if previous_agent_node_id
        edge_rows << {
          graph_id: graph.id,
          from_node_id: previous_agent_node_id,
          to_node_id: user_node_id,
          edge_type: DAG::Edge::SEQUENCE,
          metadata: {},
          created_at: now,
          updated_at: now,
        }
      end

      previous_agent_node_id = agent_node_id
    end

    DAG::Turn.insert_all!(turn_rows) if turn_rows.any?
    DAG::NodeBody.insert_all!(body_rows) if body_rows.any?
    DAG::Node.insert_all!(node_rows) if node_rows.any?
    DAG::Edge.insert_all!(edge_rows) if edge_rows.any?
  end
end

measure("transcript_page_last_20") do
  lane.transcript_page(limit_turns: 20)
end

if last_agent_node_id
  measure("context_for_last_agent") do
    graph.context_for(last_agent_node_id)
  end
end

lane.update!(next_anchored_seq: turns)
