class AutomationRun < ApplicationRecord
  STATUSES = %w[queued awaiting_approval approved running completed failed rejected canceled].freeze

  belongs_to :automation
  belongs_to :initiated_by_user, class_name: "User", optional: true
  belongs_to :conversation_run, optional: true

  before_validation :normalize_immutable_fields

  attr_readonly :automation_id, :initiated_by_user_id, :dispatch_key, :scheduled_for

  validates :dispatch_key, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :scheduled_for, presence: true
  validate :approval_state_must_be_object
  validate :snapshot_must_be_object

  private

    def normalize_immutable_fields
      if new_record? || will_save_change_to_dispatch_key?
        self.dispatch_key = dispatch_key.to_s.strip.presence
      end
      self.approval_state = approval_state.deep_stringify_keys if approval_state.is_a?(Hash)
      self.snapshot = snapshot.deep_stringify_keys if snapshot.is_a?(Hash)
    end

    def approval_state_must_be_object
      return if approval_state.is_a?(Hash)

      errors.add(:approval_state, "must be a JSON object")
    end

    def snapshot_must_be_object
      return if snapshot.is_a?(Hash) && snapshot.present?

      errors.add(:snapshot, "must be a JSON object")
    end
end
