class RuntimeSetting < ApplicationRecord
  validates :default_worker_concurrency, presence: true, numericality: { greater_than: 0, only_integer: true }
  validate :queue_overrides_must_be_object
  validate :alert_thresholds_must_be_object
  validate :singleton_row

  private

    def queue_overrides_must_be_object
      errors.add(:queue_overrides, "must be a hash") unless queue_overrides.is_a?(Hash)
    end

    def alert_thresholds_must_be_object
      errors.add(:alert_thresholds, "must be a hash") unless alert_thresholds.is_a?(Hash)
    end

    def singleton_row
      scope = self.class.all
      scope = scope.where.not(id: id) if persisted?
      errors.add(:base, "runtime settings already exist") if scope.exists?
    end
end
