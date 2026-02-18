module DAG
  class GraphHooks
    def record_event(graph:, event_type:, subject_type:, subject_id:, particulars: {})
      raise NotImplementedError, "#{self.class.name} must implement #record_event"
    end

    class Noop < GraphHooks
      def record_event(graph:, event_type:, subject_type:, subject_id:, particulars: {})
        _ = graph
        _ = event_type
        _ = subject_type
        _ = subject_id
        _ = particulars
      end
    end
  end
end
