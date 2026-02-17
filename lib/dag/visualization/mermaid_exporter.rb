module DAG
  module Visualization
    class MermaidExporter
      def initialize(graph:, include_compressed:, max_label_chars:)
        @graph = graph
        @include_compressed = include_compressed
        @max_label_chars = max_label_chars
      end

      def call
        nodes = load_nodes
        payloads = load_payloads(nodes)
        edges = load_edges(nodes)

        lines = ["flowchart TD"]

        nodes.each do |node|
          payload = payloads[node.payload_id]
          lines << %(#{node_mermaid_id(node.id)}["#{escape(label_for(node, payload))}"])
        end

        edges.each do |edge|
          lines << %(#{node_mermaid_id(edge.from_node_id)} -->|#{escape(edge_label(edge))}| #{node_mermaid_id(edge.to_node_id)})
        end

        lines.join("\n")
      end

      private

        def load_nodes
          scope = @graph.nodes
            .select(:id, :node_type, :state, :metadata, :payload_id, :compressed_at)

          scope = scope.where(compressed_at: nil) unless @include_compressed
          scope.order(:id).to_a
        end

        def load_payloads(nodes)
          payload_ids = nodes.map(&:payload_id).compact.uniq

          DAG::NodePayload.where(id: payload_ids)
            .select(:id, :type, :input, :output_preview)
            .index_by(&:id)
        end

        def load_edges(nodes)
          node_ids = nodes.map(&:id).index_with(true)

          scope = @graph.edges.select(:id, :from_node_id, :to_node_id, :edge_type, :metadata, :compressed_at)
          scope = scope.where(compressed_at: nil) unless @include_compressed

          scope.order(:id).to_a.select do |edge|
            node_ids.key?(edge.from_node_id) && node_ids.key?(edge.to_node_id)
          end
        end

        def node_mermaid_id(node_id)
          "N_#{node_id.to_s.delete("-")}"
        end

        def label_for(node, payload)
          snippet = node_snippet(node, payload)
          label = "#{node.node_type}:#{node.state}"
          label = "#{label} #{snippet}" if snippet.present?
          label.truncate(@max_label_chars)
        end

        def node_snippet(node, payload)
          input = payload&.input.is_a?(Hash) ? payload.input : {}
          output_preview = payload&.output_preview.is_a?(Hash) ? payload.output_preview : {}

          case node.node_type
          when DAG::Node::TASK
            input["name"]
          when DAG::Node::USER_MESSAGE
            input["content"].to_s
          else
            output_preview["content"].to_s
          end.to_s.gsub(/\s+/, " ").strip
        end

        def edge_label(edge)
          if edge.edge_type == DAG::Edge::BRANCH
            branch_kinds = edge.metadata["branch_kinds"]

            if branch_kinds.is_a?(Array) && branch_kinds.any?
              "branch:#{branch_kinds.join(",")}"
            else
              "branch"
            end
          else
            edge.edge_type
          end
        end

        def escape(text)
          text.to_s.gsub("\\", "\\\\").gsub("\"", "\\\"")
        end
    end
  end
end
