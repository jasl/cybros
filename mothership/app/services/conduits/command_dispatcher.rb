module Conduits
  # Three-tier command dispatch: WebSocket → Push Notification → REST Poll.
  # Phase 7: WebSocket + REST implemented; Push Notification mocked.
  class CommandDispatcher
    # @return [Symbol] :websocket, :push_notification, :poll (how the command was/will be delivered)
    def dispatch(command)
      territory = command.territory

      if territory.websocket_connected?
        push_via_websocket(command)
      elsif territory.push_token.present?
        push_via_notification(command)
      else
        :poll
      end
    rescue AASM::InvalidTransition => e
      Rails.logger.warn("[CommandDispatcher] State transition failed for command #{command.id}: #{e.message}")
      :poll
    end

    private

    def push_via_websocket(command)
      # Mark dispatched in DB first — source of truth
      command.dispatch!

      TerritoryChannel.broadcast_command(command)

      :websocket
    rescue AASM::InvalidTransition
      raise
    rescue => e
      # If broadcast fails after dispatch, the command is still dispatched —
      # the territory will pick it up via REST poll as fallback.
      Rails.logger.error("[CommandDispatcher] WebSocket broadcast failed for command #{command.id}: #{e.message}")
      :websocket
    end

    def push_via_notification(command)
      command.dispatch!

      # Phase 7: record intent to push, but don't actually call APNs/FCM
      Rails.logger.info(
        "[CommandDispatcher] push_notification fallback for command #{command.id} " \
        "(territory=#{command.territory_id}, platform=#{command.territory.push_platform}, mock)"
      )
      :push_notification
    end
  end
end
