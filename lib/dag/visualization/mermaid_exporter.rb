module DAG
  module Visualization
    class MermaidExporter
      def initialize(conversation:, include_compressed:, max_label_chars:)
        @conversation = conversation
        @include_compressed = include_compressed
        @max_label_chars = max_label_chars
      end

      def call
        nodes = @conversation.dag_nodes.preload(:runnable)
        edges = @conversation.dag_edges.includes(:from_node, :to_node)

        unless @include_compressed
          nodes = nodes.where(compressed_at: nil)
          edges = edges.where(compressed_at: nil)
        end

        nodes = nodes.order(:id).to_a
        edges = edges.order(:id).to_a

        lines = ["flowchart TD"]

        nodes.each do |node|
          lines << %(#{node_mermaid_id(node)}["#{escape(label_for(node))}"])
        end

        edges.each do |edge|
          lines << %(#{node_mermaid_id(edge.from_node)} -->|#{escape(edge_label(edge))}| #{node_mermaid_id(edge.to_node)})
        end

        lines.join("\n")
      end

      private

        def node_mermaid_id(node)
          "N_#{node.id.to_s.delete("-")}"
        end

        def label_for(node)
          snippet = node_snippet(node)
          label = "#{node.node_type}:#{node.state}"
          label = "#{label} #{snippet}" if snippet.present?
          label.truncate(@max_label_chars)
        end

        def node_snippet(node)
          case node.node_type
          when DAG::Node::TASK
            node.metadata["task_name"] || node.metadata["name"] || node.metadata["kind"]
          else
            node.runnable.content.to_s
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
