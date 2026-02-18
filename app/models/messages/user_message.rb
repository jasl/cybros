module Messages
  class UserMessage < ::DAG::NodeBody
    class << self
      def transcript_include?(_context_node_hash)
        true
      end
    end

    def editable?
      true
    end
  end
end
