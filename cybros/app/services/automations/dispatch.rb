module Automations
  class Dispatch
    def self.call!(automation:, scheduled_for:, dispatch_key:, trigger_snapshot:, initiated_by_user: nil)
      new(
        automation: automation,
        scheduled_for: scheduled_for,
        dispatch_key: dispatch_key,
        trigger_snapshot: trigger_snapshot,
        initiated_by_user: initiated_by_user,
      ).call!
    end

    def initialize(automation:, scheduled_for:, dispatch_key:, trigger_snapshot:, initiated_by_user:)
      @automation = automation
      @scheduled_for = scheduled_for
      @dispatch_key = dispatch_key.to_s
      @trigger_snapshot = trigger_snapshot.is_a?(Hash) ? trigger_snapshot.deep_stringify_keys : {}
      @initiated_by_user = initiated_by_user
    end

    def call!
      existing_run || create_run!
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

      attr_reader :automation, :scheduled_for, :dispatch_key, :trigger_snapshot, :initiated_by_user

      def existing_run
        AutomationRun.find_by(automation: automation, dispatch_key: dispatch_key)
      end

      def create_run!
        AutomationRun.transaction do
          automation_run =
            AutomationRun.create!(
              automation: automation,
              initiated_by_user: initiated_by_user,
              dispatch_key: dispatch_key,
              status: "queued",
              scheduled_for: scheduled_for,
              approval_state: {},
              snapshot: snapshot_payload,
            )
          Automations::ExecuteRunJob.perform_later(automation_run.id)
          automation_run
        end
      end

      def snapshot_payload
        {
          "automation" => automation_snapshot,
          "schedule" => schedule_snapshot,
          "trigger" => trigger_snapshot.merge("dispatch_key" => dispatch_key),
        }
      end

      def automation_snapshot
        {
          "id" => automation.id,
          "user_id" => automation.user_id,
          "conversation_id" => automation.conversation_id,
          "agent_program_id" => automation.agent_program_id,
          "execution_target_id" => automation.execution_target_id,
          "permission_mode" => automation.permission_mode,
          "task_payload" => automation.task_payload,
        }.compact
      end

      def schedule_snapshot
        {
          "kind" => automation.schedule_kind,
          "rrule" => automation.schedule_rrule,
          "timezone" => automation.schedule_timezone,
          "scheduled_for" => scheduled_for.iso8601,
        }
      end
  end
end
