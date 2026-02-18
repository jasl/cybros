module Messages
  class UserMessage < ::DAG::NodeBody
    class << self
      def turn_anchor?
        true
      end

      def transcript_candidate?
        true
      end

      def created_content_destination
        [:input, "content"]
      end

      def transcript_include?(_context_node_hash)
        true
      end
    end

    def mermaid_snippet(node:)
      _ = node
      input = self.input.is_a?(Hash) ? self.input : {}
      input["content"].to_s
    end

    def editable?
      true
    end
  end
end
