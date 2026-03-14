class AgentRPCSession < ApplicationRecord
  belongs_to :agent
  belongs_to :recognized_deployment
  belongs_to :agent_rpc_invocation, optional: true
  belongs_to :conversation, optional: true

  before_validation :normalize_allowed_methods

  validates :agent, presence: true
  validates :recognized_deployment, presence: true
  validates :recognized_deployment_key, presence: true
  validates :scope_type, presence: true
  validates :scope_id, presence: true
  validates :session_token_digest, presence: true
  validates :expires_at, presence: true
  validates :status, presence: true
  validate :allowed_methods_must_be_array

  validate :binding_consistency

  private

    def normalize_allowed_methods
      self.allowed_methods = Array(allowed_methods).map(&:to_s).reject(&:blank?).uniq
      self.recognized_deployment_key ||= recognized_deployment&.recognized_deployment_key
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
      end

      return if agent_rpc_invocation.blank?

      if agent_rpc_invocation.agent_id != agent_id ||
          agent_rpc_invocation.recognized_deployment_id != recognized_deployment_id ||
          agent_rpc_invocation.recognized_deployment_key != recognized_deployment_key ||
          agent_rpc_invocation.binding_fingerprint != deployment_fingerprint ||
          agent_rpc_invocation.deployment_activated_at != deployment_activated_at ||
          agent_rpc_invocation.scope_type != scope_type ||
          agent_rpc_invocation.scope_id != scope_id
        errors.add(:agent_rpc_invocation, "must match the recognized deployment binding")
      end

      if conversation_id.present? && agent_rpc_invocation.conversation_id.present? &&
          agent_rpc_invocation.conversation_id != conversation_id
        errors.add(:conversation, "must match the invocation binding")
      end
    end

    def allowed_methods_must_be_array
      errors.add(:allowed_methods, "must be an array") unless allowed_methods.is_a?(Array)
    end
end
