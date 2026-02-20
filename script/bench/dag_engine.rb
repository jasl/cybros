require "benchmark"
require "securerandom"

def ms(duration)
  (duration * 1000).round(1)
end

def measure(label)
  duration = Benchmark.realtime { yield }
  puts format("%<label>s: %<ms>.1fms", label: label, ms: ms(duration))
end

puts "DAG engine benchmark"
puts "Rails.env=#{Rails.env}"

measure("linear_1k_create") do
  conversation = Conversation.create!(title: "bench-linear")
  graph = conversation.dag_graph
  previous = nil

  1000.times do |i|
    node_type = i.even? ? Messages::UserMessage.node_type_key : Messages::AgentMessage.node_type_key
    body_attributes =
      if node_type == Messages::UserMessage.node_type_key
        { body_input: { "content" => "n#{i}" } }
      else
        { body_output: { "content" => "n#{i}" } }
      end
    node = graph.nodes.create!(
      node_type: node_type,
      state: DAG::Node::FINISHED,
      **body_attributes,
      metadata: {}
    )

    if previous
      graph.edges.create!(from_node_id: previous.id, to_node_id: node.id, edge_type: DAG::Edge::SEQUENCE)
    end

    previous = node
  end
end

measure("fanout_context_for") do
  conversation = Conversation.create!(title: "bench-fanout")
  graph = conversation.dag_graph
  tasks = 50.times.map do |i|
    graph.nodes.create!(
      node_type: Messages::Task.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "name" => "t#{i}" },
      metadata: {}
    )
  end

  join = graph.nodes.create!(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
  tasks.each do |task|
    graph.edges.create!(from_node_id: task.id, to_node_id: join.id, edge_type: DAG::Edge::DEPENDENCY)
  end

  graph.main_lane.context_for(join.id)
end

measure("scheduler_claim_100") do
  conversation = Conversation.create!(title: "bench-claim")
  graph = conversation.dag_graph
  100.times do
    graph.nodes.create!(node_type: Messages::Task.node_type_key, state: DAG::Node::PENDING, metadata: {})
  end

  DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 100, claimed_by: "bench")
end

conversation = Conversation.create!(title: "bench-transcript-page")
graph = conversation.dag_graph
lane = graph.main_lane
previous = nil

200.times do |i|
  turn_id = SecureRandom.uuid

  user =
    graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: turn_id,
      body_input: { "content" => "u#{i}" },
      metadata: {}
    )
  agent =
    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: turn_id,
      body_output: { "content" => "a#{i}" },
      metadata: {}
    )

  if previous
    graph.edges.create!(from_node_id: previous.id, to_node_id: user.id, edge_type: DAG::Edge::SEQUENCE)
  end

  graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

  previous = agent
end

measure("transcript_page_last_20_of_200_turns") do
  lane.transcript_page(limit_turns: 20)
end
