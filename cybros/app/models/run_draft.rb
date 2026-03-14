class RunDraft < ApplicationRecord
  include RuntimeGovernorSnapshotConsistency

  belongs_to :conversation
  belongs_to :initiated_by_user, class_name: "User", optional: true
  belongs_to :agent, optional: true
  belongs_to :recognized_deployment, optional: true
  belongs_to :provider_credential, class_name: "LLMProviderCredential", optional: true
  belongs_to :materialized_conversation_run, class_name: "ConversationRun", optional: true

  before_validation :normalize_payloads

  validates :status, presence: true
  validates :permission_mode, presence: true
  validates :trigger_snapshot, presence: true
  validates :agent, presence: true
  validates :recognized_deployment, presence: true
  validates :contract_fingerprint, presence: true
  validates :deployment_fingerprint, presence: true
  validates :deployment_activated_at, presence: true
  validates :agent_config_schema_fingerprint, presence: true
  validates :expires_at, presence: true
  validates :recognized_deployment_key, presence: true, if: :recognized_deployment_id?

  validate :binding_consistency

  def bound_conversation
    conversation
  end

  def bound_agent_node
    conversation = bound_conversation
    return nil if conversation.nil?

    node_id = trigger_snapshot["dag_node_id"].to_s.strip
    return nil if node_id.empty?

    conversation.root_graph.nodes.find_by(id: node_id)
  end

  def bound_lane
    bound_agent_node&.lane || bound_conversation&.chat_lane
  end

  def plan_invocation_id = prepare_invocation_id

  private

    def normalize_payloads
      self.trigger_snapshot = normalize_hash(self[:trigger_snapshot])
      self.runtime_governors = normalize_hash(self[:runtime_governors])
      self.planning = normalize_hash(self[:planning])
      self.staged_public_settings_patch = normalize_hash(self[:staged_public_settings_patch])
      self.staged_agent_config_patch = normalize_hash(self[:staged_agent_config_patch])
      self.approval_state = normalize_hash(self[:approval_state])
      self.staged_kv_ops = Array(self[:staged_kv_ops]).map { |value| value.is_a?(Hash) ? value.deep_stringify_keys : value }
      self.staged_prompt_buffer_ops = Array(self[:staged_prompt_buffer_ops]).map { |value| value.is_a?(Hash) ? value.deep_stringify_keys : value }
      self.agent ||= conversation&.agent || recognized_deployment&.agent
      self.recognized_deployment_key ||= recognized_deployment&.recognized_deployment_key
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def binding_consistency
      if recognized_deployment.present?
        if agent.blank?
          errors.add(:agent, "must exist")
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
      elsif contract_fingerprint.blank?
        errors.add(:contract_fingerprint, "must match the deployed contract")
      end
    end
end
