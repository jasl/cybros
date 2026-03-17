class Agent < ApplicationRecord
  SOURCE_KINDS = %w[bundled custom].freeze
  RUNTIME_STATUSES = %w[active inactive].freeze
  HEALTH_STATUSES = %w[healthy unhealthy unknown].freeze
  DEFAULT_EXECUTION_CAPACITY_QUEUE_MULTIPLIER = 4
  DEFAULT_EXECUTION_TIMEOUT_S = 900

  has_many :automations, dependent: :restrict_with_exception
  has_many :conversations, dependent: :restrict_with_exception
  has_many :recognized_deployments, dependent: :restrict_with_exception

  before_validation :normalize_contract_fields
  before_validation :normalize_runtime_binding_fields

  validates :name, presence: true
  validates :config_namespace, presence: true, uniqueness: true
  validates :published_contract_fingerprint, presence: true
  validates :config_schema_fingerprint, presence: true
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :status, inclusion: { in: RUNTIME_STATUSES }
  validates :health_status, inclusion: { in: HEALTH_STATUSES }
  validates :bundled_agent_key, presence: true, if: :bundled_source?
  validates :local_path, presence: true, if: :custom_source?

  def bundled_source? = source_kind.to_s == "bundled"
  def custom_source? = source_kind.to_s == "custom"
  def active? = status.to_s == "active"
  def healthy? = health_status.to_s == "healthy"

  def loaded_agent(loader: nil)
    loader ||= Agents::Loader.new(base_dir: absolute_local_path)
    loader.load
  end

  def contract_fingerprint
    published_contract_fingerprint.to_s
  end

  def absolute_local_path
    if bundled_source?
      Agents::BundledSources.path_for(bundled_agent_key)
    else
      resolved_custom_local_path!
    end
  end

  def supported_methods
    Array(self[:supported_methods]).map(&:to_s).reject(&:blank?).uniq
  end

  def capability_snapshot
    normalize_hash(self[:capability_snapshot])
  end

  def inspection_details
    normalize_hash(self[:inspection_details])
  end

  def transport_config
    normalize_hash(self[:transport_config])
  end

  def args
    normalize_hash(self[:args])
  end

  def manifest_snapshot
    normalize_hash(self[:manifest_snapshot])
  end

  def global_config
    normalize_hash(self[:global_config])
  end

  def global_config_schema
    normalize_hash(self[:global_config_schema])
  end

  def conversation_config_schema
    normalize_hash(self[:conversation_config_schema])
  end

  def preferred_model_refs
    snapshot = manifest_snapshot
    model = snapshot.fetch("model", nil)
    prefer = model.is_a?(Hash) ? model.fetch("prefer", nil) : model
    refs = Array(prefer).flatten.map { |value| value.to_s.strip }.reject(&:blank?).uniq
    return refs if refs.any? || snapshot.key?("model")

    []
  end

  def input_policy_config
    snapshot = manifest_snapshot
    overrides = snapshot.fetch("input_policy", nil)
    overrides = normalize_hash(overrides)
    return Cybros::AgentProfiles.global_input_policy.deep_merge(overrides) if overrides.any? || snapshot.key?("input_policy")

    Cybros::AgentProfiles.global_input_policy
  end

  def agent_key
    manifest_snapshot["agent_key"].to_s.presence ||
      bundled_agent_key.to_s.presence ||
      config_namespace.to_s.presence
  end

  def runtime_surface_config
    stored = args.fetch("runtime_surface", nil)
    return stored.deep_stringify_keys if stored.is_a?(Hash)

    Cybros::AgentProfileConfig.default_runtime_surface_metadata
  end

  def runtime_surface_status
    status = args.fetch("runtime_surface_status", nil).to_s
    return status if %w[configured missing invalid].include?(status)

    "missing"
  end

  def runtime_surface_fallback?
    runtime_surface_status != "configured"
  end

  def selectable_for_conversation?
    active_runtime_binding.present?
  end

  def conversation_metadata_fragment
    {}.tap do |metadata|
      key =
        if bundled_agent_key.to_s == "claw"
          "main"
        else
          bundled_agent_key.to_s.presence
        end
      metadata["key"] = key if key.present?
    end
  end

  def active_runtime_binding
    return nil unless active?
    return nil unless healthy?
    return nil if activated_at.blank?
    return nil if published_contract_fingerprint.to_s.blank?
    return nil if deployment_fingerprint.to_s.blank?
    return nil if runtime_transport_unconfigured?

    self
  end

  def active_healthy_deployment_for_published_contract
    active_runtime_binding
  end

  def execution_capacity_snapshot
    {
      "scope_type" => "agent",
      "scope_id" => id,
      "max_concurrent_tasks" => max_concurrent_tasks,
      "max_queued_tasks" => max_queued_tasks,
      "default_timeout_s" => default_timeout_s,
      "cpu_limit_millicores" => cpu_limit_millicores,
      "memory_limit_mb" => memory_limit_mb,
    }.compact
  end

  def supports_upload?
    available_methods =
      Array(capability_snapshot.dig("observed_runtime_identity", "supported_methods")).presence ||
        supported_methods()

    Array(available_methods).map(&:to_s).include?("attachments.import")
  end

  def allocated_port
    Integer(transport_config["port"], exception: false)
  end

  def runtime_config_path
    transport_config["runtime_config_path"].to_s.presence
  end

  def managed_local_http_jsonrpc?
    transport_kind.to_s == "http_jsonrpc" && allocated_port.present?
  end

  def close_open_rpc_sessions!(at: Time.current.change(usec: 0))
    AgentRPCSession.where(agent_id: id, status: "open").update_all(status: "closed", updated_at: at)
  end

  def workspace_root_path
    Agents::WorkspacePathResolver.resolve(agent: self)
  end

  private

    def normalize_contract_fields
      self.args = normalize_hash(self[:args])
      self.manifest_snapshot = normalize_hash(self[:manifest_snapshot])
      self.global_config = normalize_hash(self[:global_config])
      self.global_config_schema = normalize_hash(self[:global_config_schema])
      self.conversation_config_schema = normalize_hash(self[:conversation_config_schema])
    end

    def normalize_runtime_binding_fields
      self.status = status.to_s.strip.presence || "inactive"
      self.health_status = health_status.to_s.strip.presence || "unknown"
      self.supported_methods = Array(self[:supported_methods]).map(&:to_s).reject(&:blank?).uniq
      self.capability_snapshot = normalize_hash(self[:capability_snapshot])
      self.inspection_details = normalize_hash(self[:inspection_details])
      self.transport_config = normalize_hash(self[:transport_config])
    end

    def runtime_transport_unconfigured?
      transport_kind.to_s.blank? ||
        deployment_fingerprint.to_s.blank? ||
        protocol_version.to_s.blank?
    end

    def resolved_custom_local_path!
      root = RuntimeSetting.instance_agent_workspace_root_path.expand_path
      candidate = Pathname.new(local_path.to_s)
      raise ArgumentError, "local_path must be relative" if candidate.absolute?

      expanded = root.join(candidate).expand_path
      return expanded if expanded == root || expanded.to_s.start_with?(root.to_s + File::SEPARATOR)

      raise ArgumentError, "local_path escapes agent workspace root"
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end
end
