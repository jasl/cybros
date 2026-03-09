class ExecutionCapacityLease < ApplicationRecord
  STATUSES = %w[active released expired].freeze

  before_validation :normalize_payloads

  validates :subject_type, :subject_id, :execution_request_id, :holder_type, :holder_id,
    :lease_expires_at, :heartbeat_at, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :slots, numericality: { greater_than: 0, only_integer: true }
  validates :execution_request_id, uniqueness: { scope: [:subject_type, :subject_id] }

  scope :active, -> { where(status: "active") }

  private

    def normalize_payloads
      self.recovery_metadata = recovery_metadata.is_a?(Hash) ? recovery_metadata.deep_stringify_keys : {}
    end
end
