class LLMProvider < ApplicationRecord
  encrypts :api_key

  validates :name, presence: true
  validates :base_url, presence: true
  validates :api_format, presence: true, inclusion: { in: %w[openai] }
  validates :priority, numericality: { only_integer: true }

  validate :headers_must_be_a_hash
  validate :model_allowlist_must_be_strings

  private

    def headers_must_be_a_hash
      errors.add(:headers, "must be an object") unless headers.is_a?(Hash)
    end

    def model_allowlist_must_be_strings
      return if model_allowlist.is_a?(Array) && model_allowlist.all? { |v| v.is_a?(String) }

      errors.add(:model_allowlist, "must be an array of strings")
    end
end
