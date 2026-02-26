module Conduits
  # Periodically reaps expired commands (queued/dispatched past their timeout).
  # Designed to be run every 10 seconds via SolidQueue recurring schedule.
  class CommandTimeoutJob < ApplicationJob
    queue_as :conduits

    def perform
      Conduits::Command.expired.find_each do |command|
        command.time_out!
        Conduits::AuditService.new(account: command.account, command: command).record(
          "command.timed_out",
          payload: {
            command_id: command.id,
            capability: command.capability,
            territory_id: command.territory_id,
            age_seconds: (Time.current - command.created_at).round,
          }
        )
      rescue AASM::InvalidTransition => e
        Rails.logger.warn("[CommandTimeoutJob] Skipping command #{command.id}: #{e.message}")
      end
    end
  end
end
