module Messages
  class GraphHooks < DAG::GraphHooks
    def initialize(conversation:)
      @conversation = conversation
    end

    def record_event(graph:, event_type:, subject_type:, subject_id:, particulars: {})
      _ = graph
      @conversation.events.create!(
        event_type: event_type,
        subject_type: subject_type,
        subject_id: subject_id,
        particulars: particulars
      )
    end
  end
end
