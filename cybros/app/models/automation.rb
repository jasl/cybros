class Automation < ApplicationRecord
  STATUSES = %w[active paused archived].freeze
  SCHEDULE_KINDS = %w[rrule].freeze

  belongs_to :user
  belongs_to :agent, optional: true

  has_many :conversations, inverse_of: :automation

  before_validation :normalize_defaults

  validates :permission_mode, presence: true, inclusion: { in: Conversation::PERMISSION_MODES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :agent, presence: true
  validate :task_payload_must_be_object
  validate :schedule_or_trigger_definition_present
  validate :schedule_rrule_is_valid
  validate :schedule_timezone_is_valid
  validate :trigger_payload_must_be_object, if: :trigger_based?

  private

    def normalize_defaults
      self.permission_mode = permission_mode.to_s.strip.presence || "full_access"
      self.status = status.to_s.strip.presence || "active"
      self.schedule_kind = schedule_kind.to_s.strip.presence
      self.schedule_rrule = schedule_rrule.to_s.strip.presence
      self.schedule_timezone = schedule_timezone.to_s.strip.presence
      self.trigger_kind = trigger_kind.to_s.strip.presence
      self.trigger_payload = trigger_payload.is_a?(Hash) ? trigger_payload.deep_stringify_keys : {}
      self.task_payload = task_payload.deep_stringify_keys if task_payload.is_a?(Hash)
    end

    def rrule_schedule?
      schedule_kind == "rrule"
    end

    def schedule_based?
      schedule_kind.present?
    end

    def trigger_based?
      trigger_kind.present?
    end

    def task_payload_must_be_object
      return if task_payload.is_a?(Hash) && task_payload.present?

      errors.add(:task_payload, "must be a JSON object")
    end

    def schedule_or_trigger_definition_present
      if schedule_based? == trigger_based?
        errors.add(:base, "must define exactly one schedule or trigger")
        return
      end

      if schedule_based?
        errors.add(:schedule_kind, "is not included in the list") unless SCHEDULE_KINDS.include?(schedule_kind)
        errors.add(:schedule_rrule, "can't be blank") if schedule_rrule.blank?
        errors.add(:schedule_timezone, "can't be blank") if schedule_timezone.blank?
      else
        errors.add(:trigger_kind, "can't be blank") if trigger_kind.blank?
      end
    end

    def schedule_rrule_is_valid
      return unless rrule_schedule?
      return if errors[:schedule_rrule].any? || errors[:schedule_kind].any?

      Automations::ScheduleDefinition.validate_rrule!(schedule_rrule)
    rescue ArgumentError
      errors.add(:schedule_rrule, "must be a supported RRULE")
    end

    def schedule_timezone_is_valid
      return unless schedule_based?
      return if schedule_timezone.blank?
      return if ActiveSupport::TimeZone[schedule_timezone].present?

      errors.add(:schedule_timezone, "must be a valid time zone")
    end

    def trigger_payload_must_be_object
      return if trigger_payload.is_a?(Hash) && trigger_payload.present?

      errors.add(:trigger_payload, "must be a JSON object")
    end
end
