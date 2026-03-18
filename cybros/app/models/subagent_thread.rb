class SubagentThread < ApplicationRecord
  STATUSES = %w[active frozen closed killed missing].freeze
  TERMINAL_STATUSES = %w[frozen closed killed missing].freeze
  CHILD_STATUSES = %w[pending running awaiting_approval idle failed stopped missing].freeze
  TERMINAL_ORIGINS = %w[owner_action child_runtime system_reconcile integrity_guard].freeze
  DIAGNOSTIC_LEVELS = %w[standard debug].freeze

  enum :status, STATUSES.index_by(&:itself), default: "active", prefix: :status
  enum :child_status, CHILD_STATUSES.index_by(&:itself), default: "pending", prefix: :child_status

  belongs_to :owner_conversation, class_name: "Conversation", inverse_of: :owned_subagent_threads
  belongs_to :owner_graph, class_name: "DAG::Graph", inverse_of: :owned_subagent_threads
  belongs_to :owner_turn, class_name: "DAG::Turn", inverse_of: :owned_subagent_threads
  belongs_to :owner_node, class_name: "DAG::Node", inverse_of: :owned_subagent_threads
  belongs_to :child_conversation, class_name: "Conversation", inverse_of: :subagent_thread
  belongs_to :child_graph, class_name: "DAG::Graph", inverse_of: :subagent_thread

  scope :active_control, -> { where(status: "active") }

  before_validation :normalize_payloads

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :child_status, presence: true, inclusion: { in: CHILD_STATUSES }
  validates :depth, numericality: { only_integer: true, greater_than: 0 }
  validates :requested_name, :title, :agent_profile, presence: true
  validates :context_turns, numericality: { only_integer: true, greater_than: 0 }
  validates :diagnostic_level, presence: true, inclusion: { in: DIAGNOSTIC_LEVELS }
  validates :terminal_origin, inclusion: { in: TERMINAL_ORIGINS }, allow_blank: true
  validates :child_conversation, uniqueness: true
  validates :child_graph, uniqueness: true

  validate :owner_conversation_matches_owner_graph
  validate :child_conversation_matches_child_graph
  validate :owner_node_matches_owner_turn
  validate :child_conversation_parent_matches_owner

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def active?
    status == "active"
  end

  def frozen?
    status == "frozen"
  end

  def read_only?
    !active?
  end

  def snapshot_payload
    payload = final_snapshot.presence || last_snapshot
    payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
  end

  def record_snapshot!(snapshot, final: false)
    normalized = normalize_json(snapshot || {})
    attributes = {
      child_status: normalized.fetch("status", child_status),
      last_snapshot: normalized,
      result_summary: normalize_json(normalized["result"] || result_summary),
      artifacts_summary: normalize_json(normalized["artifacts"] || artifacts_summary),
    }
    attributes[:final_snapshot] = normalized if final
    update!(attributes)
  end

  def mark_frozen!(freeze_reason:, snapshot: nil, at: Time.current)
    normalized_snapshot = snapshot.is_a?(Hash) ? normalize_json(snapshot) : snapshot_payload

    update!(
      status: "frozen",
      child_status: normalized_snapshot.fetch("status", child_status),
      freeze_reason: freeze_reason.to_s.presence,
      frozen_at: at,
      owner_finalized_at: at,
      final_snapshot: normalized_snapshot,
      result_summary: normalize_json(normalized_snapshot["result"] || result_summary),
      artifacts_summary: normalize_json(normalized_snapshot["artifacts"] || artifacts_summary),
    )
  end

  def mark_missing!(reason:, at: Time.current)
    update!(
      status: "missing",
      child_status: "missing",
      terminal_origin: "integrity_guard",
      terminal_reason: reason.to_s,
      terminal_at: at,
      integrity_state: "missing",
      integrity_error: { "reason" => reason.to_s },
    )
  end

  private

    def normalize_payloads
      self.requested_name = requested_name.to_s.strip.presence
      self.title = title.to_s.strip.presence
      self.agent_profile = agent_profile.to_s.strip.presence
      self.diagnostic_level = diagnostic_level.to_s.strip.presence || "standard"
      self.terminal_origin = terminal_origin.to_s.strip.presence
      self.terminal_reason = terminal_reason.to_s.strip.presence
      self.freeze_reason = freeze_reason.to_s.strip.presence
      self.integrity_state = integrity_state.to_s.strip.presence
      self.last_snapshot = normalize_json(last_snapshot || {})
      self.final_snapshot = normalize_json(final_snapshot || {})
      self.result_summary = normalize_json(result_summary || {})
      self.artifacts_summary = normalize_json(artifacts_summary || {})
      self.last_error_snapshot = normalize_json(last_error_snapshot || {})
      self.integrity_error = normalize_json(integrity_error || {})
    end

    def owner_conversation_matches_owner_graph
      return if owner_conversation.blank? || owner_graph.blank?
      return if owner_conversation.dag_graph&.id == owner_graph_id

      errors.add(:owner_graph, "must match the owner conversation root graph")
    end

    def child_conversation_matches_child_graph
      return if child_conversation.blank? || child_graph.blank?
      return if child_conversation.dag_graph&.id == child_graph_id

      errors.add(:child_graph, "must match the child conversation root graph")
    end

    def owner_node_matches_owner_turn
      return if owner_node.blank? || owner_turn.blank? || owner_graph.blank?
      return if owner_node.graph_id == owner_graph_id && owner_node.turn_id == owner_turn_id && owner_turn.graph_id == owner_graph_id

      errors.add(:owner_node, "must belong to the owner turn and graph")
    end

    def child_conversation_parent_matches_owner
      return if child_conversation.blank? || owner_conversation.blank?
      return if child_conversation.parent_conversation_id == owner_conversation_id

      errors.add(:child_conversation, "must remain attached to the owner conversation")
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
end
