class AgentProgram < ApplicationRecord
  SOURCE_KINDS = %w[bundled custom].freeze

  has_many :agent_deployments, dependent: :restrict_with_exception
  has_many :conversations, dependent: :restrict_with_exception
  has_many :conversation_runs, dependent: :restrict_with_exception
  has_many :run_drafts, dependent: :restrict_with_exception
  has_one :active_healthy_deployment, -> { active_healthy }, class_name: "AgentDeployment"
  belongs_to :forked_from_agent_program, class_name: "AgentProgram", optional: true

  before_validation :normalize_contract_fields

  validates :name, presence: true
  validates :config_namespace, presence: true, uniqueness: true
  validates :published_contract_fingerprint, presence: true
  validates :config_schema_fingerprint, presence: true
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :bundled_agent_key, presence: true, if: :bundled_source?
  validates :local_path, presence: true, if: :custom_source?
  validate :bundled_source_must_resolve
  validate :local_path_must_match_bundled_source, if: :bundled_source?
  validate :custom_local_path_must_stay_within_workspace_root, if: :custom_source?

  scope :selectable_for_conversations, lambda {
    joins(:agent_deployments)
      .merge(AgentDeployment.active_healthy)
      .where("agent_deployments.contract_fingerprint = agent_programs.published_contract_fingerprint")
      .distinct
      .order(:name)
  }

  def global_config
    value = self[:global_config]
    value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
  end

  def manifest_snapshot
    value = self[:manifest_snapshot]
    value.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(value) : {}
  end

  def preferred_model_refs
    model = manifest_snapshot.fetch("model", nil)
    prefer = model.is_a?(Hash) ? model.fetch("prefer", nil) : model

    Array(prefer).flatten.map { |value| value.to_s.strip }.reject(&:empty?).uniq
  rescue StandardError
    []
  end

  def input_policy_config
    overrides = manifest_snapshot.fetch("input_policy", nil)
    overrides = overrides.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(overrides) : {}

    Cybros::AgentProfiles.global_input_policy.deep_merge(overrides)
  rescue StandardError
    Cybros::AgentProfiles.global_input_policy
  end

  def bundled_source? = source_kind.to_s == "bundled"
  def custom_source? = source_kind.to_s == "custom"

  def active_healthy_deployment_for_published_contract
    deployment = active_healthy_deployment
    return nil if deployment.blank?
    return nil unless deployment.contract_fingerprint.to_s == published_contract_fingerprint.to_s

    deployment
  end

  def selectable_for_conversation?
    active_healthy_deployment_for_published_contract.present?
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
    if bundled_source?
      AgentPrograms::BundledSources.path_for(bundled_agent_key)
    else
      resolved_custom_local_path!
    end
  end

  private

    def normalize_contract_fields
      self.manifest_snapshot = normalize_hash_attribute(self[:manifest_snapshot])
      self.global_config = normalize_hash_attribute(self[:global_config])
      self.global_config_schema = normalize_hash_attribute(self[:global_config_schema])
      self.conversation_config_schema = normalize_hash_attribute(self[:conversation_config_schema])

      self.config_namespace = generated_config_namespace if config_namespace.blank?
      self.local_path = generated_local_path if custom_source? && local_path.to_s.strip.blank?
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

    def generated_local_path
      base = config_namespace.to_s.parameterize(separator: "-")
      base = "agent-program" if base.blank?
      File.join("storage", "agent_programs", base)
    end

    def generated_contract_fingerprint
      payload = {
        "config_namespace" => config_namespace.to_s,
        "source_kind" => source_kind.to_s,
        "bundled_agent_key" => bundled_agent_key.to_s,
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

    def bundled_source_must_resolve
      return unless bundled_source?
      return if AgentPrograms::BundledSources.path_for(bundled_agent_key).present?

      errors.add(:bundled_agent_key, "is not a known bundled source")
    end

    def local_path_must_match_bundled_source
      expected = AgentPrograms::BundledSources.relative_path_for(bundled_agent_key)
      return if expected.blank?
      return if local_path.to_s == expected

      errors.add(:local_path, "must match the bundled source root for this key")
    end

    def configured_agent_workspace_root
      RuntimeSetting.instance_agent_workspace_root_path
    end

    def custom_local_path_must_stay_within_workspace_root
      return if local_path.to_s.strip.blank?

      resolved_custom_local_path!
    rescue ArgumentError
      errors.add(:local_path, "must stay within the configured agent workspace root")
    end

    def resolved_custom_local_path!
      root = configured_agent_workspace_root.expand_path
      candidate = Pathname.new(local_path.to_s)
      raise ArgumentError, "local_path must be relative" if candidate.absolute?

      expanded = root.join(candidate).expand_path
      return expanded if expanded == root || expanded.to_s.start_with?(root.to_s + File::SEPARATOR)

      raise ArgumentError, "local_path escapes agent workspace root"
    end
end
