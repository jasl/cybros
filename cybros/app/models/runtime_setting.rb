class RuntimeSetting < ApplicationRecord
  DEFAULT_WORKER_CONCURRENCY = 12
  TEST_AGENT_WORKSPACE_ROOT = Rails.root.join("tmp", "agent-workspace").to_s.freeze

  class InvalidAgentWorkspaceRoot < ArgumentError; end

  before_validation :apply_scope_key

  validates :scope_key, presence: true, inclusion: { in: %w[instance] }, uniqueness: true
  validates :default_worker_concurrency, presence: true, numericality: { greater_than: 0, only_integer: true }
  validates :agent_workspace_root, presence: true
  validate :queue_overrides_must_be_object
  validate :alert_thresholds_must_be_object
  validate :agent_workspace_root_must_be_absolute
  validate :agent_workspace_root_must_point_outside_app_repository
  validate :singleton_row

  def self.default_agent_workspace_root
    env_root = ENV.fetch("CYBROS_AGENT_WORKSPACE_ROOT", "").to_s.strip
    return env_root if env_root.present?
    return TEST_AGENT_WORKSPACE_ROOT if Rails.env.test?

    ""
  end

  def self.instance_agent_workspace_root_path
    configured_root = find_by(scope_key: "instance")&.agent_workspace_root.to_s.strip
    configured_root = default_agent_workspace_root if configured_root.blank?

    validate_agent_workspace_root_path!(normalize_agent_workspace_root_path(configured_root))
  end

  def self.agent_workspace_root_path_for(agent:)
    agent = agent or raise ArgumentError, "agent is required"

    if agent.bundled_source?
      key = agent.bundled_agent_key.to_s.strip
      key = agent.agent_key.to_s.strip if key.blank?
      key = "agent" if key.blank?

      return instance_agent_workspace_root_path.join("bundled", ActiveStorage::Filename.new(key).sanitized).cleanpath
    end

    prefix = agent.bundled_agent_key.to_s.strip
    prefix = agent.agent_key.to_s.strip if prefix.blank?
    prefix = "agent" if prefix.blank?

    instance_agent_workspace_root_path.join("#{ActiveStorage::Filename.new(prefix).sanitized}-#{agent.id}")
  end

  def self.skill_catalog_sources
    raw = ENV.fetch("CYBROS_SKILL_CATALOG_SOURCES", "").to_s.strip
    return [] if raw.blank?

    normalize_skill_catalog_sources(JSON.parse(raw))
  rescue JSON::ParserError
    []
  end

  def self.conversation_workspace_root_path_for(logical_workspace_key:)
    key = logical_workspace_key.to_s.strip
    raise ArgumentError, "logical workspace key is required" if key.blank?

    normalized_key = key.tr(File::SEPARATOR, "-")
    instance_agent_workspace_root_path.join("conversations", normalized_key).cleanpath
  end

  def self.normalize_agent_workspace_root_path(value)
    root = value.to_s.strip
    raise InvalidAgentWorkspaceRoot, "Agent workspace root must be configured before creating custom agents" if root.empty?
    raise InvalidAgentWorkspaceRoot, "Agent workspace root must be an absolute path" unless root.start_with?(File::SEPARATOR)

    components = root.split(File::SEPARATOR).reject(&:blank?)
    Pathname.new(File::SEPARATOR).join(*components).cleanpath
  end

  def self.validate_agent_workspace_root_path!(path)
    normalized = path.is_a?(Pathname) ? path.cleanpath : normalize_agent_workspace_root_path(path)
    return normalized unless normalized == app_repository_root_path

    raise InvalidAgentWorkspaceRoot, "Agent workspace root must point outside the Cybros app repository"
  end

  def self.app_repository_root_path
    @app_repository_root_path ||= Pathname.new(Rails.root.to_s).cleanpath
  end

  def agent_workspace_root_path
    self.class.validate_agent_workspace_root_path!(self.class.normalize_agent_workspace_root_path(agent_workspace_root))
  end

  private

    def self.normalize_skill_catalog_sources(value)
      Array(value).filter_map do |entry|
        next unless entry.is_a?(Hash)

        normalized = entry.deep_stringify_keys
        catalog = normalized["catalog"].to_s.strip
        root = normalized["root"].to_s.strip
        next if catalog.blank? || root.blank?

        {
          "catalog" => catalog,
          "root" => root,
        }
      end
    end

    def apply_scope_key
      self.scope_key = "instance" if scope_key.blank?
    end

    def queue_overrides_must_be_object
      errors.add(:queue_overrides, "must be a hash") unless queue_overrides.is_a?(Hash)
    end

    def alert_thresholds_must_be_object
      errors.add(:alert_thresholds, "must be a hash") unless alert_thresholds.is_a?(Hash)
    end

    def agent_workspace_root_must_be_absolute
      return if agent_workspace_root.to_s.strip.blank?

      agent_workspace_root_path
    rescue InvalidAgentWorkspaceRoot => e
      return unless e.message == "Agent workspace root must be an absolute path"

      errors.add(:agent_workspace_root, "must be an absolute path")
    end

    def agent_workspace_root_must_point_outside_app_repository
      return if agent_workspace_root.to_s.strip.blank?

      path = self.class.normalize_agent_workspace_root_path(agent_workspace_root)
      self.class.validate_agent_workspace_root_path!(path)
    rescue InvalidAgentWorkspaceRoot => e
      return unless e.message == "Agent workspace root must point outside the Cybros app repository"

      errors.add(:agent_workspace_root, "must point outside the Cybros app repository")
    end

    def singleton_row
      scope = self.class.where(scope_key: "instance")
      scope = scope.where.not(id: id) if persisted?
      errors.add(:base, "runtime settings already exist") if scope.exists?
    end
end
