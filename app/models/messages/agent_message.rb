module Messages
  class AgentMessage < ::DAG::NodeBody
    def retriable?
      true
    end

    def regeneratable?
      true
    end

    def preview_max_chars
      2000
    end
  end
end
