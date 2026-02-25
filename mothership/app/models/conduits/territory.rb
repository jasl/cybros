module Conduits
  class Territory < ApplicationRecord
    include AASM

    self.table_name = "conduits_territories"

    belongs_to :account, optional: true

    has_many :facilities, class_name: "Conduits::Facility",
             foreign_key: :territory_id, inverse_of: :territory, dependent: :restrict_with_error
    has_many :directives, class_name: "Conduits::Directive",
             foreign_key: :territory_id, inverse_of: :territory, dependent: :restrict_with_error

    validates :name, presence: true

    aasm column: :status, whiny_transitions: true do
      state :pending, initial: true
      state :online
      state :offline
      state :decommissioned

      event :activate, after: :log_state_change do
        transitions from: :pending, to: :online
      end

      event :go_online, after: :log_state_change do
        transitions from: :offline, to: :online
      end

      event :go_offline, after: :log_state_change do
        transitions from: :online, to: :offline
      end

      event :decommission, after: :log_state_change do
        transitions from: %i[pending online offline], to: :decommissioned
      end
    end

    def record_heartbeat!(nexus_version: nil, capacity: nil, labels: nil)
      attrs = { last_heartbeat_at: Time.current }
      attrs[:nexus_version] = nexus_version if nexus_version.present?
      attrs[:capacity] = capacity if capacity.present?
      attrs[:labels] = labels if labels.present?
      update!(attrs)

      go_online! if may_go_online?
    end

    def heartbeat_stale?(threshold: 5.minutes)
      last_heartbeat_at.nil? || last_heartbeat_at < threshold.ago
    end

    # Returns true if the territory's sandbox driver for the given profile is healthy.
    # Defaults to true when no health data is available yet (graceful startup).
    def sandbox_healthy?(profile)
      health = capacity&.dig("sandbox_health")
      return true if health.blank?

      driver_name = case profile.to_s
                    when "untrusted"
                      # Use the explicit untrusted_driver from heartbeat to avoid
                      # mapping divergence when the Go side uses firecracker vs bwrap.
                      capacity&.dig("untrusted_driver") || "bwrap"
                    when "trusted" then "container"
                    when "host" then "host"
                    when "darwin-automation" then "darwin-automation"
                    else profile.to_s
                    end

      result = health[driver_name]
      result.nil? || result["healthy"] != false
    end

    private

    def log_state_change
      Rails.logger.info(
        "[Territory:#{id}] State changed to #{aasm.current_state} at #{Time.current.iso8601}"
      )
    end
  end
end
