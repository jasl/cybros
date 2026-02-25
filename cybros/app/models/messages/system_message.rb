module Messages
  class SystemMessage < ::DAG::NodeBody
    class << self
      def created_content_destination
        [:input, "content"]
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
