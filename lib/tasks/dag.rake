require "json"

namespace :dag do
  desc "Audit a DAG graph (prints issues as JSON)"
  task :audit, [:graph_id] => :environment do |_task, args|
    graph_id = args[:graph_id]
    raise Cybros::Error, "graph_id required" if graph_id.blank?

    graph = DAG::Graph.find_by(id: graph_id)
    raise ActiveRecord::RecordNotFound, "graph not found id=#{graph_id}" if graph.nil?

    issues = DAG::GraphAudit.scan(graph: graph)
    puts JSON.pretty_generate(issues)
  end

  desc "Repair common DAG graph issues (best-effort)"
  task :repair, [:graph_id] => :environment do |_task, args|
    graph_id = args[:graph_id]
    raise Cybros::Error, "graph_id required" if graph_id.blank?

    graph = DAG::Graph.find_by(id: graph_id)
    raise ActiveRecord::RecordNotFound, "graph not found id=#{graph_id}" if graph.nil?

    result = DAG::GraphAudit.repair!(graph: graph)
    puts JSON.pretty_generate(result)
  end
end
