class Conversation < ApplicationRecord
  has_one :dag_graph, class_name: "DAG::Graph", as: :attachable,
          dependent: :destroy, autosave: true
  delegate :mutate!, :compress!, :kick!, :context_for, :context_for_full, :to_mermaid,
           to: :dag_graph, allow_nil: false

  has_many :events, dependent: :destroy

  after_initialize do
    build_dag_graph if new_record? && dag_graph.nil?
  end

  def record_event!(event_type:, subject:, particulars: {})
    events.create!(event_type: event_type, subject: subject, particulars: particulars)
  end
end
