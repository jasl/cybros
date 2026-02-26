module Conduits
  class AuditEvent < ApplicationRecord
    self.table_name = "conduits_audit_events"

    belongs_to :account
    belongs_to :directive, class_name: "Conduits::Directive", inverse_of: :audit_events,
               optional: true
    belongs_to :command, class_name: "Conduits::Command", optional: true
    belongs_to :actor, class_name: "User", optional: true

    SEVERITIES = %w[info warn critical].freeze
    # Informational catalog of known event types. Used for documentation and
    # querying — NOT enforced via validation so new event types don't silently
    # drop audit records (AuditService has error isolation).
    EVENT_TYPES = %w[
      directive.created
      directive.policy_evaluated
      directive.capability_capped
      directive.policy_forbidden
      directive.command_forbidden
      directive.approved
      directive.rejected
      directive.lease_policy_revalidated
      directive.started
      directive.finished
      directive.state_changed
      directive.lease_expired
      command.created
      command.awaiting_approval
      command.approved
      command.rejected
      command.dispatched
      command.completed
      command.failed
      command.timed_out
      command.canceled
      command.policy_denied
    ].freeze

    validates :event_type, presence: true
    validates :severity, presence: true, inclusion: { in: SEVERITIES }

    scope :by_type, ->(type) { where(event_type: type) }
    scope :recent, -> { order(created_at: :desc).limit(100) }
    scope :critical, -> { where(severity: "critical") }
  end
end
