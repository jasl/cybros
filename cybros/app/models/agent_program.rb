class AgentProgram < ApplicationRecord
  has_many :agent_deployments, dependent: :restrict_with_exception
  has_many :conversations, dependent: :restrict_with_exception
  has_many :conversation_runs, dependent: :restrict_with_exception
  has_many :run_drafts, dependent: :restrict_with_exception

  before_validation :normalize_contract_fields

  validates :name, presence: true
  validates :config_namespace, presence: true, uniqueness: true
  validates :published_contract_fingerprint, presence: true
  validates :config_schema_fingerprint, presence: true

  def global_config
    value = self[:global_config]
    value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
  end

  def manifest_snapshot
    value = self[:manifest_snapshot]
    value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
  end

  def bundled_profile?
    profile_source.to_s.strip != ""
  end

  def runtime_surface_config
    stored = runtime_surface_snapshot.fetch("runtime_surface", nil)
    stored.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(stored) : default_runtime_surface_config
  rescue StandardError
    default_runtime_surface_config
  end

  def runtime_surface_status
    status = runtime_surface_snapshot.fetch("runtime_surface_status", nil).to_s
    return status if %w[configured missing invalid].include?(status)

    loaded_program.runtime_surface_status
  rescue StandardError
    "missing"
  end

  def runtime_surface_fallback?
    runtime_surface_status != "configured"
  end

  def runtime_surface_label
    label = runtime_surface_config.fetch("type", "noop").to_s
    runtime_surface_fallback? ? "#{label} (fallback)" : label
  end

  def refresh_runtime_surface_snapshot(loader: nil)
    loaded = loader || loaded_program
    current = args.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(args) : {}
    current["runtime_surface"] = loaded.runtime_surface_config
    current["runtime_surface_status"] = loaded.runtime_surface_status
    current
  rescue StandardError
    {
      "runtime_surface" => default_runtime_surface_config,
      "runtime_surface_status" => "missing",
    }
  end

  def loaded_program(loader: nil)
    loader ||= AgentPrograms::Loader.new(base_dir: absolute_local_path)
    loader.load
  end

  def absolute_local_path
    Rails.root.join(local_path.to_s)
  end

  private

    def normalize_contract_fields
      self.manifest_snapshot = normalize_hash_attribute(self[:manifest_snapshot])
      self.global_config = normalize_hash_attribute(self[:global_config])
      self.global_config_schema = normalize_hash_attribute(self[:global_config_schema])
      self.conversation_config_schema = normalize_hash_attribute(self[:conversation_config_schema])

      self.config_namespace = generated_config_namespace if config_namespace.blank?
      self.config_schema_fingerprint = generated_config_schema_fingerprint if config_schema_fingerprint.blank?
      self.published_contract_fingerprint = generated_contract_fingerprint if published_contract_fingerprint.blank?
    end

    def normalize_hash_attribute(value)
      value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
    end

    def generated_config_namespace
      base = name.to_s.parameterize(separator: ".")
      base = "agent.program" if base.blank?
      "#{base}.#{SecureRandom.hex(4)}"
    end

    def generated_config_schema_fingerprint
      payload = {
        "global_config_schema" => normalize_hash_attribute(self[:global_config_schema]),
        "conversation_config_schema" => normalize_hash_attribute(self[:conversation_config_schema]),
      }
      "config:sha256:#{Digest::SHA256.hexdigest(payload.to_json)}"
    end

    def generated_contract_fingerprint
      payload = {
        "config_namespace" => config_namespace.to_s,
        "manifest_snapshot" => normalize_hash_attribute(self[:manifest_snapshot]),
        "global_config_schema" => normalize_hash_attribute(self[:global_config_schema]),
        "conversation_config_schema" => normalize_hash_attribute(self[:conversation_config_schema]),
      }
      "contract:sha256:#{Digest::SHA256.hexdigest(payload.to_json)}"
    end

    def runtime_surface_snapshot
      current = args.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(args) : {}
      return current if current["runtime_surface"].is_a?(Hash) && current["runtime_surface_status"].present?

      loaded_program.then do |loaded|
        {
          "runtime_surface" => loaded.runtime_surface_config,
          "runtime_surface_status" => loaded.runtime_surface_status,
        }
      end
    rescue StandardError
      {
        "runtime_surface" => default_runtime_surface_config,
        "runtime_surface_status" => "missing",
      }
    end

    def default_runtime_surface_config
      Cybros::AgentProfileConfig.default_runtime_surface_metadata
    end
end
