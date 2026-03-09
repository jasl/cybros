class RunDraft < ApplicationRecord
  belongs_to :conversation
  belongs_to :initiated_by_user, class_name: "User", optional: true
  belongs_to :agent_program
  belongs_to :agent_deployment
  belongs_to :provider_credential, class_name: "LLMProviderCredential", optional: true
  belongs_to :proposed_execution_target, class_name: "ExecutionTarget", optional: true
  belongs_to :materialized_conversation_run, class_name: "ConversationRun", optional: true

  before_validation :normalize_payloads

  validates :status, presence: true
  validates :permission_mode, presence: true
  validates :trigger_snapshot, presence: true
  validates :contract_fingerprint, presence: true
  validates :deployment_fingerprint, presence: true
  validates :deployment_activated_at, presence: true
  validates :expires_at, presence: true

  validate :binding_consistency
  validate :governor_snapshot_consistency

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

  private

    def normalize_payloads
      self.trigger_snapshot = normalize_hash(self[:trigger_snapshot])
      self.runtime_governors = normalize_hash(self[:runtime_governors])
      self.prepared_plan = normalize_hash(self[:prepared_plan])
      self.staged_public_settings_patch = normalize_hash(self[:staged_public_settings_patch])
      self.staged_agent_config_patch = normalize_hash(self[:staged_agent_config_patch])
      self.approval_state = normalize_hash(self[:approval_state])
      self.staged_kv_ops = Array(self[:staged_kv_ops]).map { |value| value.is_a?(Hash) ? value.deep_stringify_keys : value }
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def binding_consistency
      return if agent_program.blank? || agent_deployment.blank?

      if agent_deployment.agent_program_id != agent_program_id
        errors.add(:agent_deployment, "must belong to the selected agent program")
      end

      if agent_deployment.contract_fingerprint != contract_fingerprint
        errors.add(:contract_fingerprint, "must match the deployed contract")
      end

      if agent_deployment.deployment_fingerprint != deployment_fingerprint
        errors.add(:deployment_fingerprint, "must match the selected deployment")
      end
    end

    def governor_snapshot_consistency
      provider_snapshot = runtime_governors["provider_limiter"]
      execution_snapshot = runtime_governors["execution_capacity"]

      if provider_credential_id.present? || selected_model_ref.present?
        unless provider_snapshot.is_a?(Hash)
          errors.add(:runtime_governors, "must include a provider_limiter snapshot")
          return
        end

        if provider_credential_id.present? && provider_snapshot["provider_credential_id"].to_s != provider_credential_id.to_s
          errors.add(:runtime_governors, "must snapshot the selected provider credential")
        end

        selected_provider_key = selected_model_ref.to_s.split("/", 2).first.to_s
        if selected_provider_key.present? && provider_snapshot["provider_key"].to_s != selected_provider_key
          errors.add(:runtime_governors, "must snapshot the selected model provider")
        end
      end

      return unless proposed_execution_target_id.present?

      unless execution_snapshot.is_a?(Hash)
        errors.add(:runtime_governors, "must include an execution_capacity snapshot")
        return
      end

      if execution_snapshot["execution_target_id"].to_s != proposed_execution_target_id.to_s
        errors.add(:runtime_governors, "must snapshot the selected execution target")
      end

      expected_location_id = proposed_execution_target&.execution_location_id
      if expected_location_id.present? && execution_snapshot["execution_location_id"].to_s != expected_location_id.to_s
        errors.add(:runtime_governors, "must snapshot the target execution location")
      end
    end
end
