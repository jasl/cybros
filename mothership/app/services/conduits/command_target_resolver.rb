module Conduits
  class NoTargetAvailable < StandardError; end

  # Resolves the target territory (and optional bridge entity) for a command
  # based on capability, location, tag, or direct ID.
  class CommandTargetResolver
    Result = Data.define(:territory, :entity)

    def resolve(account:, capability:, target:)
      target = target.with_indifferent_access if target.is_a?(Hash)

      # 1. Direct territory_id specified
      if target[:territory_id].present?
        territory = account.territories.find(target[:territory_id])
        entity = resolve_entity(territory, capability, target)
        return Result.new(territory: territory, entity: entity)
      end

      # 2. Search by capability + location + tag among direct territories
      # Prefer the most recently active territory (deterministic ordering)
      scope = account.territories.where(status: :online)
      scope = scope.with_capability(capability)
      scope = scope.at_location(target[:location]) if target[:location].present?
      scope = scope.with_tag(target[:tag]) if target[:tag].present?

      territory = scope.order(last_heartbeat_at: :desc, id: :asc).first

      if territory
        return Result.new(territory: territory, entity: nil)
      end

      # 3. Search bridge entities (prefer most recently seen)
      entity_scope = Conduits::BridgeEntity
                       .joins(:territory)
                       .where(territory: { account_id: account.id })
                       .available
                       .with_capability(capability)

      entity_scope = entity_scope.at_location(target[:location]) if target[:location].present?

      entity = entity_scope.order(last_seen_at: :desc, id: :asc).includes(:territory).first

      if entity
        return Result.new(territory: entity.territory, entity: entity)
      end

      raise NoTargetAvailable, "No device found for #{capability} at #{target.to_h}"
    end

    private

    def resolve_entity(territory, capability, target)
      return nil unless territory.kind == "bridge"

      scope = territory.bridge_entities.available.with_capability(capability)

      if target[:entity_ref].present?
        return scope.find_by!(entity_ref: target[:entity_ref])
      end

      scope.order(last_seen_at: :desc, id: :asc).first
    end
  end
end
