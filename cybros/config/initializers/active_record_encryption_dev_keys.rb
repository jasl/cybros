# frozen_string_literal: true

# Ensure development can run without credentials by providing stable
# Active Record Encryption keys when none are configured.
#
# Production must provide real keys via ENV or credentials.
if Rails.env.development?
  require "fileutils"
  require "securerandom"
  require "yaml"

  config = Rails.application.config.active_record.encryption

  keys_present =
    config.primary_key.present? &&
      config.deterministic_key.present? &&
      config.key_derivation_salt.present?

  unless keys_present
    dir = Rails.root.join("tmp")
    FileUtils.mkdir_p(dir)
    path = dir.join("active_record_encryption_keys.yml")

    data =
      if path.file?
        YAML.safe_load(path.read, permitted_classes: [], permitted_symbols: [], aliases: false)
      else
        {
          "primary_key" => SecureRandom.alphanumeric(32),
          "deterministic_key" => SecureRandom.alphanumeric(32),
          "key_derivation_salt" => SecureRandom.alphanumeric(32),
        }
      end

    data = {} unless data.is_a?(Hash)
    required = %w[primary_key deterministic_key key_derivation_salt]
    missing = required.any? { |key| data[key].to_s == "" }
    if missing
      data =
        {
          "primary_key" => SecureRandom.alphanumeric(32),
          "deterministic_key" => SecureRandom.alphanumeric(32),
          "key_derivation_salt" => SecureRandom.alphanumeric(32),
        }
    end

    config.primary_key ||= data["primary_key"]
    config.deterministic_key ||= data["deterministic_key"]
    config.key_derivation_salt ||= data["key_derivation_salt"]

    File.write(path, YAML.dump(data))
    File.chmod(0o600, path)
  end
end

