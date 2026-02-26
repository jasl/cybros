module Conduits
  class Territory < ApplicationRecord
    include AASM

    self.table_name = "conduits_territories"

    KINDS = %w[server desktop mobile bridge].freeze
    PUSH_PLATFORMS = %w[apns fcm].freeze

    belongs_to :account, optional: true

    has_many :facilities, class_name: "Conduits::Facility",
             foreign_key: :territory_id, inverse_of: :territory, dependent: :restrict_with_error
    has_many :directives, class_name: "Conduits::Directive",
             foreign_key: :territory_id, inverse_of: :territory, dependent: :restrict_with_error
    has_many :commands, class_name: "Conduits::Command",
             foreign_key: :territory_id, inverse_of: :territory, dependent: :restrict_with_error
    has_many :bridge_entities, class_name: "Conduits::BridgeEntity",
             foreign_key: :territory_id, inverse_of: :territory, dependent: :destroy

    validates :name, presence: true
    validates :kind, inclusion: { in: KINDS }
    validates :push_platform, inclusion: { in: PUSH_PLATFORMS }, allow_nil: true

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

    # --- Capability scopes ---

    scope :with_capability, ->(cap) {
      where("capabilities @> ?", [cap].to_json)
    }

    scope :with_capability_matching, ->(pattern) {
      if pattern.end_with?(".*")
        prefix = pattern.delete_suffix(".*")
        where("EXISTS (SELECT 1 FROM jsonb_array_elements_text(capabilities) AS c WHERE c LIKE ?)", "#{sanitize_sql_like(prefix)}.%")
      else
        with_capability(pattern)
      end
    }

    scope :at_location, ->(loc) {
      where("location LIKE ?", "#{sanitize_sql_like(loc)}%")
    }

    scope :with_tag, ->(tag) {
      where("tags @> ?", [tag].to_json)
    }

    scope :websocket_connected, -> {
      where.not(websocket_connected_at: nil)
    }

    scope :command_capable, -> {
      where(status: :online).where("capabilities != '[]'::jsonb")
    }

    scope :directive_capable, -> {
      where(status: :online, kind: %w[server desktop])
    }

    # --- Heartbeat ---

    def record_heartbeat!(nexus_version: nil, capacity: nil, labels: nil, capabilities: nil, runtime_status: nil)
      attrs = { last_heartbeat_at: Time.current }
      attrs[:nexus_version] = nexus_version if nexus_version.present?
      attrs[:capacity] = capacity if capacity.present?
      attrs[:labels] = labels if labels.present?
      attrs[:capabilities] = capabilities if capabilities.present?
      attrs[:runtime_status] = runtime_status if runtime_status.present?
      update!(attrs)

      go_online! if may_go_online?
    end

    def heartbeat_stale?(threshold: 5.minutes)
      last_heartbeat_at.nil? || last_heartbeat_at < threshold.ago
    end

    # Returns the number of directives currently running on this territory
    # as reported by the last heartbeat. Returns 0 if not reported.
    def running_directives_count
      runtime_status&.dig("running_directives").to_i
    end

    # Returns the max_concurrent capacity for this territory.
    # Defaults to 1 if not specified.
    def max_concurrent
      capacity&.dig("max_concurrent").to_i.then { |v| v.positive? ? v : 1 }
    end

    # Returns true if territory has available slots based on last heartbeat report.
    def has_capacity?
      running_directives_count < max_concurrent
    end

    # Returns true if the territory's sandbox driver for the given profile is healthy.
    # Defaults to true when no health data is available yet (graceful startup).
    def sandbox_healthy?(profile)
      health = capacity&.dig("sandbox_health")
      return true if health.blank?

      driver_name = case profile.to_s
      when "untrusted"
                      capacity&.dig("untrusted_driver") || "bwrap"
      when "trusted" then "container"
      when "host" then "host"
      when "darwin-automation" then "darwin-automation"
      else profile.to_s
      end

      result = health[driver_name]
      result.nil? || result["healthy"] != false
    end

    # --- WebSocket connection tracking ---

    def websocket_connected?
      websocket_connected_at.present?
    end

    # --- Kind helpers ---

    def supports_directives?
      kind.in?(%w[server desktop])
    end

    def supports_commands?
      true
    end

    private

    def log_state_change
      Rails.logger.info(
        "[Territory:#{id}] State changed to #{aasm.current_state} at #{Time.current.iso8601}"
      )
    end
  end
end
