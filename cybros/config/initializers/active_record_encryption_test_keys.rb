# frozen_string_literal: true

# Ensure tests can run without credentials files by providing deterministic
# Active Record Encryption keys when none are configured.
#
# Production must still provide real keys via ENV or credentials.
if Rails.env.test?
  require "securerandom"

  config = Rails.application.config.active_record.encryption

  config.primary_key ||= SecureRandom.alphanumeric(32)
  config.deterministic_key ||= SecureRandom.alphanumeric(32)
  config.key_derivation_salt ||= SecureRandom.alphanumeric(32)
end

