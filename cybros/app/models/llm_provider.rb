class LLMProvider < ApplicationRecord
  encrypts :api_key
  encrypts :access_token
  encrypts :refresh_token

  validates :provider_key, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9_-]*\z/ }
  validates :credential_type, presence: true, inclusion: { in: %w[api_key oauth_codex] }

  private
end
