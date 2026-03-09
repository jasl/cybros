class AgentRpcInvocation < ApplicationRecord
  belongs_to :agent_deployment
  belongs_to :conversation, optional: true
  belongs_to :last_session, class_name: "AgentRpcSession", optional: true

  has_many :agent_rpc_sessions, dependent: :nullify
  has_many :agent_rpc_operation_receipts, dependent: :destroy

  before_validation :normalize_payloads

  validates :scope_type, presence: true
  validates :scope_id, presence: true
  validates :method, presence: true
  validates :invocation_id, presence: true,
    uniqueness: {
      scope: %i[
        agent_deployment_id
        binding_fingerprint
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

  private

    def normalize_payloads
      self.result_snapshot = normalize_hash(self[:result_snapshot])
      self.error_snapshot = normalize_hash(self[:error_snapshot])
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end
end
