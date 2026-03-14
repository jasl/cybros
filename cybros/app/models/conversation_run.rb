class ConversationRun < ApplicationRecord
  include RuntimeGovernorSnapshotConsistency

  STATES = %w[queued running succeeded failed canceled].freeze
  SNAPSHOT_FIELDS = %i[
    snapshot_version
    initiated_by_user_id
    effective_permission_mode
    agent_id
    recognized_deployment_id
    recognized_deployment_key
    contract_fingerprint
    deployment_fingerprint
    deployment_activated_at
    provider_credential_id
    selected_model_ref
    effective_public_settings
    effective_agent_config
    agent_config_schema_fingerprint
    effective_policy
    runtime_governors
    snapshot
  ].freeze

  belongs_to :conversation
  belongs_to :initiated_by_user, class_name: "User", optional: true
  belongs_to :agent, optional: true
  belongs_to :recognized_deployment, optional: true
  belongs_to :provider_credential, class_name: "LLMProviderCredential", optional: true

  attr_readonly(*SNAPSHOT_FIELDS)

  validates :dag_node_id, presence: true
  validates :state, presence: true, inclusion: { in: STATES }
  validates :queued_at, presence: true
  validates :snapshot_version, presence: true
  validates :effective_permission_mode, presence: true
  validates :agent, presence: true
  validates :recognized_deployment, presence: true
  validates :recognized_deployment_key, presence: true
  validates :contract_fingerprint, presence: true
  validates :deployment_fingerprint, presence: true
  validates :deployment_activated_at, presence: true

  validate :binding_consistency

  before_validation :normalize_snapshot_payloads, on: :create

  def self.latest_for_node(node_or_id)
    node_id = node_or_id.respond_to?(:id) ? node_or_id.id : node_or_id
    return nil if node_id.blank?

    run = where(dag_node_id: node_id).order(:id).last
    return run if run
    return nil unless node_or_id.respond_to?(:turn_id)

    turn_id = node_or_id.turn_id.to_s
    lane_id = node_or_id.respond_to?(:lane_id) ? node_or_id.lane_id.to_s : ""
    graph_id = node_or_id.respond_to?(:graph_id) ? node_or_id.graph_id.to_s : ""
    return nil if turn_id.blank? || lane_id.blank? || graph_id.blank?

    conversation = conversation_for_runtime_node(node_or_id)
    scope = conversation ? where(conversation_id: conversation.id) : all
    agent_node_ids =
      DAG::Node.where(
        graph_id: graph_id,
        lane_id: lane_id,
        turn_id: turn_id,
        node_type: [Messages::AgentMessage.node_type_key, Messages::CharacterMessage.node_type_key],
      ).select(:id)

    scope.where(dag_node_id: agent_node_ids).order(:id).last
  end

  def self.conversation_for_runtime_node(node)
    lane_attachable = node.respond_to?(:lane) ? node.lane&.attachable : nil
    return lane_attachable if lane_attachable.is_a?(Conversation)

    graph_attachable = node.respond_to?(:graph) ? node.graph&.attachable : nil
    return graph_attachable if graph_attachable.is_a?(Conversation)

    nil
  rescue StandardError
    nil
  end
  private_class_method :conversation_for_runtime_node

  def queued? = state == "queued"
  def running? = state == "running"
  def succeeded? = state == "succeeded"
  def failed? = state == "failed"
  def canceled? = state == "canceled"
  def programmable? = snapshot["draft"].is_a?(Hash)
  def on_context_pressure_invocation_id(node:) = runtime_hook_invocation_id("on_context_pressure", node: node)
  def before_subagent_spawn_invocation_id(node:) = runtime_hook_invocation_id("before_subagent_spawn", node: node)
  def before_finalize_output_invocation_id(node:) = runtime_hook_invocation_id("before_finalize_output", node: node)
  def after_task_notice_invocation_id(node:) = runtime_hook_invocation_id("after_task_notice", node: node)
  def after_subagent_result_invocation_id(node:) = runtime_hook_invocation_id("after_subagent_result", node: node)
  def execution_capacity_snapshot
    runtime_governors["execution_capacity"] if runtime_governors.is_a?(Hash)
  end
  def execution_capacity_governed? = execution_capacity_snapshot.is_a?(Hash)

  def waiting_for_capacity?
    queued? &&
      RuntimeWait.parked.exists?(
        owner_type: self.class.name,
        owner_id: id,
        reason_type: "execution_capacity",
      )
  end

  def runtime_state
    waiting_for_capacity? ? "waiting_for_capacity" : state
  end

  def mark_running!(at: Time.current)
    update!(state: "running", started_at: at) if queued?
  end

  def mark_succeeded!(at: Time.current)
    update!(state: "succeeded", finished_at: at) if running? || queued?
  end

  def mark_failed!(message:, at: Time.current)
    payload = error.is_a?(Hash) ? error : {}
    payload = payload.deep_stringify_keys
    payload["message"] = message.to_s
    update!(state: "failed", finished_at: at, error: payload) if running? || queued?
  end

  def mark_canceled!(at: Time.current)
    update!(state: "canceled", finished_at: at) if running? || queued?
  end

  private

    def normalize_snapshot_payloads
      self.effective_public_settings = normalize_hash(self[:effective_public_settings])
      self.effective_agent_config = normalize_hash(self[:effective_agent_config])
      self.effective_policy = normalize_hash(self[:effective_policy])
      self.runtime_governors = normalize_hash(self[:runtime_governors])
      self.snapshot = normalize_hash(self[:snapshot])
      self.agent ||= conversation&.agent || recognized_deployment&.agent
      self.recognized_deployment_key ||= recognized_deployment&.recognized_deployment_key
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def runtime_hook_invocation_id(hook_name, node:)
      node_id = node.respond_to?(:id) ? node.id : node
      "conversation_run:#{id}:#{hook_name}:#{node_id}"
    end

    def binding_consistency
      if recognized_deployment.present?
        if agent.blank?
          errors.add(:agent, "can't be blank")
        elsif recognized_deployment.agent_id != agent_id
          errors.add(:recognized_deployment, "must belong to the selected agent")
        end

        if recognized_deployment_key.to_s != recognized_deployment.recognized_deployment_key.to_s
          errors.add(:recognized_deployment_key, "must match the recognized deployment")
        end

        if recognized_deployment.contract_fingerprint.present? &&
            recognized_deployment.contract_fingerprint.to_s != contract_fingerprint.to_s
          errors.add(:contract_fingerprint, "must match the recognized deployment")
        end

        if recognized_deployment.deployment_fingerprint.to_s != deployment_fingerprint.to_s
          errors.add(:deployment_fingerprint, "must match the recognized deployment")
        end
      end
    end
end
