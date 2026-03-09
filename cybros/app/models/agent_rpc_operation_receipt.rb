class AgentRpcOperationReceipt < ApplicationRecord
  belongs_to :agent_rpc_invocation

  before_validation :normalize_response_snapshot

  validates :operation_id, presence: true, uniqueness: { scope: :agent_rpc_invocation_id }
  validates :method, presence: true
  validates :payload_hash, presence: true
  validates :status, presence: true

  private

    def normalize_response_snapshot
      self.response_snapshot =
        if self[:response_snapshot].is_a?(Hash)
          self[:response_snapshot].deep_stringify_keys
        else
          {}
        end
    end
end
