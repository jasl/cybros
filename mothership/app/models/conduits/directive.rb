module Conduits
  class Directive < ApplicationRecord
    include AASM

    self.table_name = "conduits_directives"

    belongs_to :account
    belongs_to :facility,  class_name: "Conduits::Facility",  inverse_of: :directives
    belongs_to :territory, class_name: "Conduits::Territory", inverse_of: :directives,
               optional: true

    belongs_to :requested_by_user, class_name: "User"
    belongs_to :approved_by_user,  class_name: "User", optional: true

    has_one_attached :diff_blob

    has_many :log_chunks, class_name: "Conduits::LogChunk",
             foreign_key: :directive_id, inverse_of: :directive, dependent: :delete_all
    has_many :audit_events, class_name: "Conduits::AuditEvent",
             foreign_key: :directive_id, inverse_of: :directive, dependent: :delete_all

    validates :sandbox_profile, presence: true,
              inclusion: { in: %w[untrusted trusted host darwin-automation] }
    validates :command, presence: true

    aasm column: :state do
      state :queued, initial: true
      state :awaiting_approval
      state :leased
      state :running
      state :succeeded
      state :failed
      state :canceled
      state :timed_out

      # Poll assigns directive to a territory with a lease
      event :lease do
        transitions from: :queued, to: :leased, guard: :territory_assigned?
      end

      # Nexus reports execution started
      event :start do
        transitions from: :leased, to: :running
      end

      # Terminal states from Nexus finished report
      event :succeed do
        transitions from: :running, to: :succeeded
      end

      event :fail do
        transitions from: :running, to: :failed
      end

      # Approval grants — transitions awaiting_approval back to queued
      event :approve do
        transitions from: :awaiting_approval, to: :queued
      end

      # Approval rejection — transitions awaiting_approval to canceled
      event :reject do
        transitions from: :awaiting_approval, to: :canceled
      end

      event :cancel do
        transitions from: %i[queued awaiting_approval leased running], to: :canceled
      end

      event :time_out do
        transitions from: :running, to: :timed_out
      end

      # Lease expired without heartbeat — return to queue
      event :expire_lease do
        transitions from: :leased, to: :queued, after: %i[clear_lease_fields unlock_facility_if_locked]
      end
    end

    # Scopes for poll/lease logic
    scope :assignable, -> { where(state: :queued) }
    scope :pending_approval, -> { where(state: :awaiting_approval) }
    scope :with_expired_lease, -> { where(state: :leased).where("lease_expires_at < ?", Time.current) }

    def lease_expired?
      leased? && lease_expires_at.present? && lease_expires_at < Time.current
    end

    def renew_lease!(ttl_seconds:)
      new_expiry = Time.current + ttl_seconds.seconds
      update!(lease_expires_at: new_expiry, last_heartbeat_at: Time.current)
    end

    def max_output_bytes
      max = (limits.is_a?(Hash) ? limits["max_output_bytes"] : nil).to_i
      max = 2_000_000 if max <= 0
      max
    end

    def max_diff_bytes
      max = (limits.is_a?(Hash) ? limits["max_diff_bytes"] : nil).to_i
      max = 1_048_576 if max <= 0
      max
    end

    def cancel_requested?
      cancel_requested_at.present?
    end

    def request_cancel!
      return if cancel_requested?

      update!(cancel_requested_at: Time.current)

      # Push cancel signal via WebSocket for immediate delivery.
      # Fire-and-forget: Nexus heartbeat is the fallback discovery mechanism.
      TerritoryChannel.broadcast_directive_cancel(self)
    end

    private

    def territory_assigned?
      territory_id.present?
    end

    def clear_lease_fields
      # AASM's fire! only persists the state column via update_column,
      # so we must explicitly save these fields to the database.
      update_columns(
        territory_id: nil,
        lease_expires_at: nil,
        last_heartbeat_at: nil
      )
    end

    def unlock_facility_if_locked
      return unless facility&.locked_by_directive_id == id

      facility.unlock!(self)
    end
  end
end
