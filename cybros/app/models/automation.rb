class Automation < ApplicationRecord
  STATUSES = %w[active paused archived].freeze
  SCHEDULE_KINDS = %w[rrule].freeze

  belongs_to :user
  belongs_to :conversation, optional: true
  belongs_to :agent_program
  belongs_to :execution_target

  has_many :automation_runs, dependent: :restrict_with_exception

  before_validation :normalize_defaults

  validates :permission_mode, presence: true, inclusion: { in: Conversation::PERMISSION_MODES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :schedule_kind, presence: true, inclusion: { in: SCHEDULE_KINDS }
  validates :schedule_rrule, presence: true, if: :rrule_schedule?
  validates :schedule_timezone, presence: true, if: :rrule_schedule?
  validate :task_payload_must_be_object

  private

    def normalize_defaults
      self.permission_mode = permission_mode.to_s.strip.presence || "full_access"
      self.status = status.to_s.strip.presence || "active"
      self.schedule_kind = schedule_kind.to_s.strip
      self.schedule_rrule = schedule_rrule.to_s.strip.presence
      self.schedule_timezone = schedule_timezone.to_s.strip.presence
      self.task_payload = task_payload.deep_stringify_keys if task_payload.is_a?(Hash)
    end

    def rrule_schedule?
      schedule_kind == "rrule"
    end

    def task_payload_must_be_object
      return if task_payload.is_a?(Hash) && task_payload.present?

      errors.add(:task_payload, "must be a JSON object")
    end
end
