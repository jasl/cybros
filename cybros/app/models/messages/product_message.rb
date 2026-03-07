module Messages
  class ProductMessage < ::DAG::NodeBody
    class << self
      def transcript_candidate?
        true
      end

      def leaf_terminal?
        true
      end

      def transcript_include?(_context_node_hash)
        true
      end
    end

    def preview_max_chars
      2000
    end
  end
end
