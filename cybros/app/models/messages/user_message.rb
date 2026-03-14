module Messages
  class UserMessage < ::DAG::NodeBody
    ATTACHMENTS_INPUT_KEY = "attachments".freeze

    class << self
      def turn_head?
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

    def deletable?
      true
    end

    def forkable?
      false
    end

    def mermaid_snippet(node:)
      _ = node
      input = self.input.is_a?(Hash) ? self.input : {}
      input["content"].to_s
    end

    def editable?
      true
    end

    def attachments
      raw = input.is_a?(Hash) ? input[ATTACHMENTS_INPUT_KEY] : nil
      Array(raw).select { |entry| entry.is_a?(Hash) }
    end

    def has_attachments?
      attachments.any?
    end
  end
end
