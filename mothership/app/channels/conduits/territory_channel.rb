module Conduits
  class TerritoryChannel < ApplicationCable::Channel
    def subscribed
      territory = current_territory
      return reject unless territory

      stream_for territory
      territory.update!(websocket_connected_at: Time.current)

      Conduits::AuditService.new(account: territory.account).record(
        "territory.websocket_connected",
        payload: { "territory_id" => territory.id, "territory_name" => territory.name }
      )
    end

    def unsubscribed
      territory = current_territory
      return unless territory

      territory.update!(websocket_connected_at: nil)

      Conduits::AuditService.new(account: territory.account).record(
        "territory.websocket_disconnected",
        payload: { "territory_id" => territory.id }
      )
    end

    # Territory can submit command results directly via WebSocket
    def command_result(data)
      command = Conduits::Command.find_by(id: data["command_id"])
      return unless command
      return unless command.territory_id == current_territory.id

      process_command_result(command, data)
    end

    # --- Class-level broadcast helpers ---

    # Push a directive cancel signal to a territory via WebSocket.
    # Fire-and-forget: failure is safe — Nexus will discover cancel via heartbeat fallback.
    def self.broadcast_directive_cancel(directive)
      territory = directive.territory
      return unless territory&.websocket_connected?

      broadcast_to(territory, {
        type: "directive_cancel",
        directive_id: directive.id,
      })
    rescue => e
      Rails.logger.error(
        "[TerritoryChannel] directive_cancel broadcast failed for #{directive.id}: #{e.message}"
      )
    end

    # Push a command to a territory via WebSocket (existing dispatch path).
    # Fire-and-forget: failure is safe — territory will discover command via REST poll fallback.
    def self.broadcast_command(command)
      broadcast_to(command.territory, {
        type: "command",
        command_id: command.id,
        capability: command.capability,
        params: command.params,
        bridge_entity_ref: command.bridge_entity&.entity_ref,
        timeout_seconds: command.timeout_seconds,
      })
    rescue => e
      Rails.logger.error(
        "[TerritoryChannel] command broadcast failed for #{command.id}: #{e.message}"
      )
    end

    private

    def process_command_result(command, data)
      status = data["status"].to_s
      result_data = data["result"] || {}
      error_msg = data["error_message"]
      incoming_hash = command.compute_result_hash(
        status: status, result_data: result_data, error_message: error_msg
      )

      unless status.in?(%w[completed failed])
        Rails.logger.warn(
          "[TerritoryChannel] Invalid status '#{status}' for command #{command.id}, ignoring"
        )
        return
      end

      ActiveRecord::Base.transaction do
        command.lock!

        # Idempotency: if already terminal, check hash consistency (mirrors REST endpoint)
        if command.terminal?
          if command.result_hash.present? && command.result_hash != incoming_hash
            Rails.logger.warn(
              "[TerritoryChannel] result_hash mismatch for command #{command.id} " \
              "(already #{command.state})"
            )
          end
          next
        end

        command.update!(
          result: result_data,
          error_message: error_msg,
          result_hash: incoming_hash
        )

        if data["attachment_base64"].present?
          begin
            raw_b64 = data["attachment_base64"]
            max_b64_size = (Conduits::Command::MAX_ATTACHMENT_BYTES * 4 / 3) + 4
            if raw_b64.bytesize > max_b64_size
              Rails.logger.warn("[TerritoryChannel] Attachment exceeds size limit for command #{command.id}")
              raise ActiveRecord::Rollback
            end

            decoded = Base64.strict_decode64(raw_b64)
            command.result_attachment.attach(
              io: StringIO.new(decoded),
              filename: data["attachment_filename"] || "result",
              content_type: data["attachment_content_type"] || "application/octet-stream"
            )
          rescue ArgumentError => e
            Rails.logger.warn("[TerritoryChannel] Invalid base64 attachment for command #{command.id}: #{e.message}")
          end
        end

        status == "completed" ? command.complete! : command.fail!
      end

      Conduits::AuditService.new(account: command.account, command: command).record(
        "command.#{command.state}",
        payload: {
          command_id: command.id,
          capability: command.capability,
          territory_id: command.territory_id,
          via: "websocket",
        }
      )
    rescue AASM::InvalidTransition => e
      Rails.logger.warn("[TerritoryChannel] State transition failed for command #{command.id}: #{e.message}")
    end
  end
end
