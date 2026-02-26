module Conduits
  # Synchronize bridge entities reported in heartbeat with the database.
  # Uses full-reconcile: upsert reported entities, mark missing ones unavailable.
  class BridgeEntitySyncService
    def sync(territory:, reported_entities:)
      return unless territory.kind == "bridge"
      return if reported_entities.blank?

      ActiveRecord::Base.transaction do
        existing = territory.bridge_entities.index_by(&:entity_ref)
        reported_refs = Set.new

        reported_entities.each do |entry|
          ref = entry["entity_ref"].to_s.strip
          next if ref.blank?

          reported_refs.add(ref)

          attrs = {
            entity_type: entry["entity_type"],
            display_name: entry["display_name"],
            capabilities: Array(entry["capabilities"]),
            location: entry["location"],
            state: entry["state"] || {},
            available: entry.fetch("available", true),
            last_seen_at: Time.current,
          }

          if existing[ref]
            existing[ref].update!(attrs)
          else
            territory.bridge_entities.create!(
              attrs.merge(
                account: territory.account,
                entity_ref: ref
              )
            )
          end
        end

        # Mark missing entities as unavailable
        missing_refs = existing.keys - reported_refs.to_a
        if missing_refs.any?
          territory.bridge_entities.where(entity_ref: missing_refs).update_all(available: false)
        end
      end
    end
  end
end
