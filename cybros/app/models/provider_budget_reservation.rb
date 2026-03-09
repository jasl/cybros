class ProviderBudgetReservation < ApplicationRecord
  STATUSES = %w[active settled released expired].freeze

  belongs_to :provider_credential, class_name: "LLMProviderCredential"

  before_validation :normalize_payloads

  validates :provider_request_id, :reserved_until, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :request_units, :estimated_tokens, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :actual_tokens, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true
  validates :provider_request_id, uniqueness: { scope: :provider_credential_id }

  scope :active, -> { where(status: "active") }

  private

    def normalize_payloads
      self.reconciliation_metadata = reconciliation_metadata.is_a?(Hash) ? reconciliation_metadata.deep_stringify_keys : {}
    end
end
