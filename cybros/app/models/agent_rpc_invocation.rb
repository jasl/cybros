class AgentRPCInvocation < ApplicationRecord
  belongs_to :agent
  belongs_to :recognized_deployment
  belongs_to :conversation, optional: true
  belongs_to :last_session, class_name: "AgentRPCSession", optional: true

  has_many :agent_rpc_sessions, dependent: :nullify
  has_many :agent_rpc_operation_receipts, dependent: :destroy

  before_validation :normalize_payloads

  validates :agent, presence: true
  validates :recognized_deployment, presence: true
  validates :recognized_deployment_key, presence: true
  validates :scope_type, presence: true
  validates :scope_id, presence: true
  validates :method, presence: true
  validates :invocation_id, presence: true,
    uniqueness: {
      scope: %i[
        agent_id
        recognized_deployment_key
        deployment_activated_at
        scope_type
        scope_id
        method
      ],
    }
  validates :binding_fingerprint, presence: true
  validates :deployment_activated_at, presence: true
  validates :request_payload_hash, presence: true
  validates :status, presence: true

  validate :binding_consistency

  private

    def normalize_payloads
      self.result_snapshot = normalize_hash(self[:result_snapshot])
      self.error_snapshot = normalize_hash(self[:error_snapshot])
      self.recognized_deployment_key ||= recognized_deployment&.recognized_deployment_key
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def binding_consistency
      return if recognized_deployment.blank?

      if agent.blank?
        errors.add(:agent, "must exist")
      elsif recognized_deployment.agent_id != agent_id
        errors.add(:recognized_deployment, "must belong to the selected agent")
      end

      if recognized_deployment_key.to_s != recognized_deployment.recognized_deployment_key.to_s
        errors.add(:recognized_deployment_key, "must match the recognized deployment")
      end

      if last_session.present? &&
          (last_session.agent_id != agent_id ||
            last_session.recognized_deployment_id != recognized_deployment_id ||
            last_session.recognized_deployment_key != recognized_deployment_key)
        errors.add(:last_session, "must match the recognized deployment binding")
      end
    end
end
