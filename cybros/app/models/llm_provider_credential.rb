class LLMProviderCredential < ApplicationRecord
  CREDENTIAL_TYPES = %w[api_key oauth_codex].freeze
  STATUSES = %w[active inactive].freeze

  encrypts :api_key
  encrypts :access_token
  encrypts :refresh_token

  validates :provider_key, presence: true, format: { with: /\A[a-z0-9][a-z0-9_-]*\z/ }
  validates :credential_type, presence: true, inclusion: { in: CREDENTIAL_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :max_concurrent_requests,
            :requests_per_minute,
            :tokens_per_minute,
            :burst_limit,
            presence: true,
            if: :active?
  validates :max_concurrent_requests, :requests_per_minute, :tokens_per_minute, :burst_limit,
    numericality: { greater_than: 0, only_integer: true },
    allow_nil: true
  validates :backoff_policy, presence: true, if: :active?
  validate :backoff_policy_must_be_hash
  validate :single_active_credential_per_provider_key

  def active?
    status == "active"
  end

  private

    def backoff_policy_must_be_hash
      errors.add(:backoff_policy, "must be a hash") unless backoff_policy.is_a?(Hash)
    end

    def single_active_credential_per_provider_key
      return unless active?
      return if provider_key.blank?

      scope = self.class.where(provider_key: provider_key, status: "active")
      scope = scope.where.not(id: id) if persisted?
      errors.add(:provider_key, :taken) if scope.exists?
    end
end
