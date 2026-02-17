module Messages
  class ToolCall < ::DAG::NodePayload
    def apply_finished_content!(content)
      merge_output!("result" => content)
    end
  end
end
