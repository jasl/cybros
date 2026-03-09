class AutomationRun < ApplicationRecord
  STATUSES = %w[queued awaiting_approval approved running completed failed rejected canceled].freeze

  belongs_to :automation
  belongs_to :initiated_by_user, class_name: "User", optional: true
  belongs_to :conversation_run, optional: true

  attr_readonly :automation_id, :initiated_by_user_id, :conversation_run_id, :scheduled_for, :snapshot

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :scheduled_for, presence: true
  validate :approval_state_must_be_object
  validate :snapshot_must_be_object

  private

    def approval_state_must_be_object
      return if approval_state.is_a?(Hash)

      errors.add(:approval_state, "must be a JSON object")
    end

    def snapshot_must_be_object
      return if snapshot.is_a?(Hash) && snapshot.present?

      errors.add(:snapshot, "must be a JSON object")
    end
end
