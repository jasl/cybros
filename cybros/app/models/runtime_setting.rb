class RuntimeSetting < ApplicationRecord
  DEFAULT_WORKER_CONCURRENCY = 12
  DEFAULT_AGENT_WORKSPACE_ROOT = Rails.root.to_s

  before_validation :apply_scope_key

  validates :scope_key, presence: true, inclusion: { in: %w[instance] }, uniqueness: true
  validates :default_worker_concurrency, presence: true, numericality: { greater_than: 0, only_integer: true }
  validates :agent_workspace_root, presence: true
  validate :queue_overrides_must_be_object
  validate :alert_thresholds_must_be_object
  validate :agent_workspace_root_must_be_absolute
  validate :singleton_row

  private

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
      root = agent_workspace_root.to_s.strip
      return if root.blank?
      return if Pathname.new(root).absolute?

      errors.add(:agent_workspace_root, "must be an absolute path")
    end

    def singleton_row
      scope = self.class.where(scope_key: "instance")
      scope = scope.where.not(id: id) if persisted?
      errors.add(:base, "runtime settings already exist") if scope.exists?
    end
end
