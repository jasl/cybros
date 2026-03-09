class ExecutionTarget < ApplicationRecord
  STATUSES = %w[active inactive unhealthy].freeze

  belongs_to :execution_location
  belongs_to :workspace

  validates :name, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :max_concurrent_tasks_override, :max_queued_tasks_override, :default_timeout_s_override,
    :cpu_limit_millicores_override, :memory_limit_mb_override,
    numericality: { greater_than: 0, only_integer: true },
    allow_nil: true
  validate :workspace_belongs_to_execution_location

  private

    def workspace_belongs_to_execution_location
      return if workspace.blank? || execution_location.blank?
      return if workspace.execution_location_id == execution_location_id

      errors.add(:workspace, "must belong to the execution location")
    end
end
