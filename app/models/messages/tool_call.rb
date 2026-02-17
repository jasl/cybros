module Messages
  class ToolCall < ::DAG::NodeBody
    def retriable?
      true
    end

    def apply_finished_content!(content)
      merge_output!("result" => content)
    end
  end
end
