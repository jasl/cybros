class Workspace < ApplicationRecord
  STATUSES = %w[active inactive unhealthy].freeze

  belongs_to :execution_location
  has_many :execution_targets, dependent: :restrict_with_exception

  validates :name, :root_path, :workspace_type, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :root_path_unique_within_execution_location

  private

    def root_path_unique_within_execution_location
      return if root_path.blank? || execution_location_id.blank?

      scope = self.class.where(execution_location_id: execution_location_id, root_path: root_path)
      scope = scope.where.not(id: id) if persisted?
      errors.add(:root_path, :taken) if scope.exists?
    end
end
