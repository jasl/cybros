module Conduits
  # Broadcasts a lightweight wake-up notification to WebSocket-connected territories
  # when a directive becomes claimable (queued). Nexus responds by calling POST /polls
  # to claim work via the existing PollService. Fire-and-forget: broadcast failure
  # does not affect correctness — REST poll catches up within 2 seconds.
  class DirectiveNotifier
    HEARTBEAT_INTERVAL_WS = 300   # 5 minutes when WebSocket connected
    HEARTBEAT_INTERVAL_REST = 30  # 30 seconds when REST-only

    def notify(directive)
      return unless directive.queued?

      territories = Territory
        .where(account_id: directive.account_id)
        .directive_capable
        .websocket_connected

      return if territories.empty?

      payload = {
        type: "directive_available",
        directive_id: directive.id,
        sandbox_profile: directive.sandbox_profile,
      }

      territories.find_each do |territory|
        TerritoryChannel.broadcast_to(territory, payload)
      end

      AuditService.new(account: directive.account, directive: directive)
        .record("directive.wake_up_broadcast", payload: {
          "territory_count" => territories.count,
          "via" => "websocket",
        })
    rescue => e
      Rails.logger.error(
        "[DirectiveNotifier] Broadcast failed for directive #{directive.id}: #{e.message}"
      )
    end
  end
end
