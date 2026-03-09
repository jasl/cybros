class ExecutionLocation < ApplicationRecord
  STATUSES = %w[active inactive unhealthy].freeze

  has_many :workspaces, dependent: :restrict_with_exception
  has_many :execution_targets, dependent: :restrict_with_exception

  scope :active, -> { where(status: "active") }

  validates :name, :kind, :platform, :status, :trust_group, :environment, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :max_concurrent_tasks, :max_queued_tasks, :default_timeout_s, presence: true
  validates :max_concurrent_tasks, :max_queued_tasks, :default_timeout_s,
    numericality: { greater_than: 0, only_integer: true }
  validates :cpu_limit_millicores, :memory_limit_mb,
    numericality: { greater_than: 0, only_integer: true },
    allow_nil: true
end
