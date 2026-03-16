class TurnInternalTask < ApplicationRecord
  STATUSES = %w[queued materializing materialized running finished canceled superseded failed_materialization].freeze
  TERMINAL_STATUSES = %w[finished canceled superseded failed_materialization].freeze
  EXECUTION_MODES = %w[serial parallel_safe].freeze

  belongs_to :conversation
  belongs_to :graph, class_name: "DAG::Graph"
  belongs_to :lane, class_name: "DAG::Lane"
  belongs_to :turn, class_name: "DAG::Turn", foreign_key: :turn_id
  belongs_to :source_node, class_name: "DAG::Node", foreign_key: :source_node_id
  belongs_to :materialized_task_node, class_name: "DAG::Node", optional: true
  belongs_to :superseded_by, class_name: "TurnInternalTask", optional: true

  scope :ordered, -> { order(:queue_position, :id) }
  scope :nonterminal, -> { where.not(status: TERMINAL_STATUSES) }

  before_validation :normalize_attributes

  validates :turn_id, presence: true
  validates :source_node_id, presence: true
  validates :source_hook_name, presence: true
  validates :source_fingerprint, presence: true, uniqueness: { scope: :turn_id }
  validates :logical_tool_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :execution_mode, presence: true, inclusion: { in: EXECUTION_MODES }
  validates :queue_position, numericality: { only_integer: true, greater_than: 0 }

  validate :lane_belongs_to_graph
  validate :lane_attached_to_conversation
  validate :conversation_root_graph_matches_graph
  validate :turn_matches_graph_and_lane
  validate :source_node_matches_turn_and_lane
  validate :materialized_task_node_matches_graph

  def operation_envelope
    metadata = authored_metadata.is_a?(Hash) ? authored_metadata : {}

    {
      "tool_call_id" => input.fetch("tool_call_id", "turn_internal_task:#{id}").to_s,
      "logical_tool_name" => logical_tool_name,
      "arguments" => operation_arguments,
      "reason" => metadata["reason"],
      "origin" => metadata["origin"],
      "approval_hint" => metadata["approval_hint"],
      "idempotency_key" => metadata["idempotency_key"],
      "sequence_id" => metadata["sequence_id"],
      "step_index" => metadata["step_index"],
      "step_count" => metadata["step_count"],
    }
  end

  private

    def normalize_attributes
      self.source_hook_name = source_hook_name.to_s.strip.presence
      self.source_fingerprint = source_fingerprint.to_s.strip.presence
      self.logical_tool_name = logical_tool_name.to_s.strip.presence
      self.effective_tool_id = effective_tool_id.to_s.strip.presence
      self.implementation_source = implementation_source.to_s.strip.presence
      self.implementation_ref = implementation_ref.to_s.strip.presence
      self.status = status.to_s.strip.presence || "queued"
      self.execution_mode = execution_mode.to_s.strip.presence || "serial"
      self.input = normalize_json(input || {})
      self.authored_metadata = normalize_json(authored_metadata || {})
    end

    def lane_belongs_to_graph
      return if lane.blank? || graph.blank?
      return if lane.graph_id == graph_id

      errors.add(:lane, "must belong to the selected graph")
    end

    def lane_attached_to_conversation
      return if lane.blank? || conversation.blank?
      return if lane.attachable == conversation

      errors.add(:lane, "must be attached to the owning conversation")
    end

    def conversation_root_graph_matches_graph
      return if conversation.blank? || graph.blank?
      return if conversation.root_graph&.id == graph_id

      errors.add(:graph, "must match the conversation root graph")
    end

    def turn_matches_graph_and_lane
      return if turn.blank? || graph.blank? || lane.blank?
      return if turn.graph_id == graph_id && turn.lane_id == lane_id

      errors.add(:turn, "must belong to the selected graph and lane")
    end

    def source_node_matches_turn_and_lane
      return if source_node.blank? || graph.blank? || lane.blank? || turn_id.blank?
      return if source_node.graph_id == graph_id && source_node.lane_id == lane_id && source_node.turn_id == turn_id

      errors.add(:source_node, "must belong to the selected turn and lane")
    end

    def materialized_task_node_matches_graph
      return if materialized_task_node.blank? || graph.blank?
      return if materialized_task_node.graph_id == graph_id

      errors.add(:materialized_task_node, "must belong to the selected graph")
    end

    def normalize_json(payload)
      case payload
      when Hash
        payload.each_with_object({}) do |(nested_key, nested_value), normalized|
          normalized[nested_key.to_s] = normalize_json(nested_value)
        end
      when Array
        payload.map { |element| normalize_json(element) }
      else
        payload
      end
    end

    def operation_arguments
      if input.is_a?(Hash) && input["arguments"].is_a?(Hash)
        normalize_json(input["arguments"])
      else
        normalize_json(input || {})
      end
    end
end
