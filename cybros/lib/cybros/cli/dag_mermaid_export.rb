module Cybros
  module CLI
    class DAGMermaidExport
      class << self
        def call(conversation_id:, include_compressed: false, max_label_chars: 80)
          conversation = Conversation.find(conversation_id)
          graph = conversation.dag_graph

          {
            "conversation" => conversation_summary(conversation),
            "graph" => graph_summary(graph),
            "analysis" => analyze_graph(graph, include_compressed: include_compressed),
            "mermaid" => graph.to_mermaid(include_compressed: include_compressed, max_label_chars: max_label_chars),
          }
        end

        private

          def conversation_summary(conversation)
            {
              "id" => conversation.id,
              "title" => conversation.title,
            }
          end

          def graph_summary(graph)
            {
              "id" => graph.id,
            }
          end

          def analyze_graph(graph, include_compressed:)
            node_ids = load_node_ids(graph, include_compressed: include_compressed)
            edge_pairs = load_edge_pairs(graph, node_ids: node_ids, include_compressed: include_compressed)

            parents_by_child = Hash.new { |hash, key| hash[key] = [] }
            neighbors = Hash.new { |hash, key| hash[key] = [] }

            edge_pairs.each do |from_node_id, to_node_id|
              parents_by_child[to_node_id] << from_node_id
              neighbors[from_node_id] << to_node_id
              neighbors[to_node_id] << from_node_id
            end

            roots = node_ids.select { |node_id| parents_by_child[node_id].empty? }
            component_sizes = component_sizes_for(node_ids: node_ids, neighbors: neighbors)

            {
              "node_count" => node_ids.length,
              "edge_count" => edge_pairs.length,
              "root_count" => roots.length,
              "root_node_ids" => roots,
              "component_count" => component_sizes.length,
              "component_sizes" => component_sizes.sort.reverse,
            }
          end

          def load_node_ids(graph, include_compressed:)
            scope = include_compressed ? graph.nodes : graph.nodes.active
            scope.order(:id).pluck(:id)
          end

          def load_edge_pairs(graph, node_ids:, include_compressed:)
            return [] if node_ids.empty?

            scope = include_compressed ? graph.edges : graph.edges.active
            scope.where(from_node_id: node_ids, to_node_id: node_ids).pluck(:from_node_id, :to_node_id)
          end

          def component_sizes_for(node_ids:, neighbors:)
            visited = {}
            sizes = []

            node_ids.each do |node_id|
              next if visited[node_id]

              size = 0
              stack = [node_id]

              until stack.empty?
                current = stack.pop
                next if visited[current]

                visited[current] = true
                size += 1
                neighbors[current].each { |neighbor| stack << neighbor unless visited[neighbor] }
              end

              sizes << size
            end

            sizes
          end
      end
    end
  end
end
