module Messages
  class AgentMessage < ::DAG::NodeBody
    def retriable?
      true
    end

    def regeneratable?
      true
    end
  end
end
