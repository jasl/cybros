module Conduits
  class Command < ApplicationRecord
    include AASM

    self.table_name = "conduits_commands"

    belongs_to :account
    belongs_to :territory, class_name: "Conduits::Territory", inverse_of: :commands
    belongs_to :bridge_entity, class_name: "Conduits::BridgeEntity", optional: true
    belongs_to :requested_by_user, class_name: "User", optional: true
    belongs_to :approved_by_user, class_name: "User", optional: true

    MAX_ATTACHMENT_BYTES = 10.megabytes

    has_one_attached :result_attachment

    validates :capability, presence: true
    validates :timeout_seconds, numericality: { greater_than: 0, less_than_or_equal_to: 300 }
    validate :capability_supported_by_territory
    validate :bridge_entity_belongs_to_territory

    aasm column: :state, whiny_transitions: true do
      state :queued, initial: true
      state :awaiting_approval
      state :dispatched
      state :completed
      state :failed
      state :timed_out
      state :canceled

      event :request_approval do
        transitions from: :queued, to: :awaiting_approval
      end

      event :approve do
        transitions from: :awaiting_approval, to: :queued
      end

      event :reject do
        transitions from: :awaiting_approval, to: :canceled
        after { update!(completed_at: Time.current) }
      end

      event :dispatch do
        transitions from: :queued, to: :dispatched
        after { update!(dispatched_at: Time.current) }
      end

      event :complete do
        transitions from: :dispatched, to: :completed
        after { update!(completed_at: Time.current) }
      end

      event :fail do
        transitions from: [:queued, :dispatched], to: :failed
        after { update!(completed_at: Time.current) }
      end

      event :time_out do
        transitions from: [:queued, :dispatched, :awaiting_approval], to: :timed_out
        after { update!(completed_at: Time.current) }
      end

      event :cancel do
        transitions from: [:queued, :dispatched, :awaiting_approval], to: :canceled
        after { update!(completed_at: Time.current) }
      end
    end

    scope :pending, -> { where(state: %w[queued dispatched]) }
    scope :pending_approval, -> { where(state: "awaiting_approval") }
    scope :for_territory, ->(tid) { where(territory_id: tid) }
    scope :expired, -> {
      where(state: %w[queued dispatched awaiting_approval])
        .where("created_at + (timeout_seconds * interval '1 second') < ?", Time.current)
    }

    def terminal?
      state.in?(%w[completed failed timed_out canceled])
    end

    # Compute idempotency hash for result submission.
    def compute_result_hash(status:, result_data:, error_message:)
      canonical = {
        "status" => status.to_s,
        "result" => normalize_json(result_data || {}),
        "error_message" => error_message,
      }
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    private

    def capability_supported_by_territory
      return if territory.nil?
      return if territory.capabilities&.include?(capability)

      if bridge_entity.present?
        return if bridge_entity.capabilities&.include?(capability)
      end

      errors.add(:capability, "#{capability} is not supported by this territory")
    end

    def bridge_entity_belongs_to_territory
      return if bridge_entity.nil?
      return if bridge_entity.territory_id == territory_id

      errors.add(:bridge_entity, "does not belong to the target territory")
    end

    def normalize_json(value)
      case value
      when Hash
        value.map { |k, v| [k.to_s, normalize_json(v)] }.sort_by(&:first).to_h
      when Array
        value.map { |v| normalize_json(v) }
      else
        value
      end
    end
  end
end
