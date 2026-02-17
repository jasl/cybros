require "benchmark"

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
  previous = nil

  1000.times do |i|
    node = conversation.dag_nodes.create!(
      node_type: (i.even? ? DAG::Node::USER_MESSAGE : DAG::Node::AGENT_MESSAGE),
      state: DAG::Node::FINISHED,
      content: "n#{i}",
      metadata: {}
    )

    if previous
      conversation.dag_edges.create!(from_node_id: previous.id, to_node_id: node.id, edge_type: DAG::Edge::SEQUENCE)
    end

    previous = node
  end
end

measure("fanout_context_for") do
  conversation = Conversation.create!(title: "bench-fanout")
  tasks = 50.times.map do |i|
    conversation.dag_nodes.create!(
      node_type: DAG::Node::TASK,
      state: DAG::Node::FINISHED,
      metadata: { "name" => "t#{i}" }
    )
  end

  join = conversation.dag_nodes.create!(node_type: DAG::Node::AGENT_MESSAGE, state: DAG::Node::PENDING, metadata: {})
  tasks.each do |task|
    conversation.dag_edges.create!(from_node_id: task.id, to_node_id: join.id, edge_type: DAG::Edge::DEPENDENCY)
  end

  conversation.context_for(join.id)
end

measure("scheduler_claim_100") do
  conversation = Conversation.create!(title: "bench-claim")
  100.times do
    conversation.dag_nodes.create!(node_type: DAG::Node::TASK, state: DAG::Node::PENDING, metadata: {})
  end

  DAG::Scheduler.claim_runnable_nodes(conversation_id: conversation.id, limit: 100)
end
