module Conduits
  class BridgeEntity < ApplicationRecord
    self.table_name = "conduits_bridge_entities"

    belongs_to :territory, class_name: "Conduits::Territory", inverse_of: :bridge_entities
    belongs_to :account

    validates :entity_ref, presence: true, uniqueness: { scope: :territory_id }
    validates :entity_type, presence: true
    validate :territory_must_be_bridge

    scope :available, -> { where(available: true) }
    scope :of_type, ->(type) { where(entity_type: type) }

    scope :with_capability, ->(cap) {
      where("conduits_bridge_entities.capabilities @> ?", [cap].to_json)
    }

    scope :at_location, ->(loc) {
      where("conduits_bridge_entities.location LIKE ?", "#{sanitize_sql_like(loc)}%")
    }

    private

    def territory_must_be_bridge
      errors.add(:territory, "must be a bridge") unless territory&.kind == "bridge"
    end
  end
end
