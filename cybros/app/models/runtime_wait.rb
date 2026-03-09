class RuntimeWait < ApplicationRecord
  STATUSES = %w[parked resumed cancelled expired].freeze
  REASONS = %w[provider_limit execution_capacity deployment_backoff].freeze

  before_validation :normalize_payloads

  validates :owner_type, :owner_id, :reason_type, :subject_type, :subject_id,
    :retry_at, :ordering_key, :status, presence: true
  validates :reason_type, inclusion: { in: REASONS }
  validates :status, inclusion: { in: STATUSES }

  scope :parked, -> { where(status: "parked") }

  private

    def normalize_payloads
      self.details = details.is_a?(Hash) ? details.deep_stringify_keys : {}
    end
end
