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
      @dispatch_key = normalize_dispatch_key(dispatch_key)
      @trigger_snapshot = trigger_snapshot.is_a?(Hash) ? trigger_snapshot.deep_stringify_keys : {}
      @initiated_by_user = initiated_by_user
    end

    def call!
      existing_conversation || create_execution_conversation!
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

      attr_reader :automation, :scheduled_for, :dispatch_key, :trigger_snapshot, :initiated_by_user

      def existing_conversation
        Conversation.find_by(automation: automation, automation_dispatch_key: dispatch_key)
      end

      def create_execution_conversation!
        Conversation.transaction do
          conversation =
            Conversation.create!(
              user: automation.user,
              automation: automation,
              automation_dispatch_key: dispatch_key,
              automation_triggered_at: scheduled_for,
              title: conversation_title,
              agent_program: automation.agent_program,
              default_execution_target: automation.execution_target,
              permission_mode: automation.permission_mode,
              metadata: conversation_metadata,
            )

          Automations::ExecutionStateRecorder.queued!(
            conversation: conversation,
            initiated_by_user: initiated_by_user,
            scheduled_for: scheduled_for,
            dispatch_key: dispatch_key,
          )
          Automations::ExecuteConversationJob.perform_later(conversation.id)
          conversation
        end
      end

      def conversation_title
        prompt = automation_prompt.squish
        return "Automation execution" if prompt.blank?

        "Automation: #{prompt}".truncate(120)
      end

      def conversation_metadata
        {
          "automation" => automation_snapshot,
          "schedule" => schedule_snapshot,
          "trigger" => trigger_snapshot.merge("dispatch_key" => dispatch_key, "user_input" => automation_prompt).compact,
          "llm" => { "model_ref" => selected_model_ref }.compact,
        }
      end

      def automation_snapshot
        {
          "id" => automation.id,
          "user_id" => automation.user_id,
          "agent_program_id" => automation.agent_program_id,
          "execution_target_id" => automation.execution_target_id,
          "permission_mode" => automation.permission_mode,
          "task_payload" => automation.task_payload.deep_dup,
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

      def selected_model_ref
        automation.task_payload["selected_model_ref"].to_s.presence
      end

      def automation_prompt
        automation.task_payload["prompt"].to_s
      end

      def normalize_dispatch_key(value)
        normalized = value.to_s.strip
        return normalized if normalized.present?

        AgentCore::ValidationError.raise!(
          "Automation dispatch requires a dispatch key.",
          code: "cybros.automations.dispatch_key_missing",
          details: {
            automation_id: automation.id,
            scheduled_for: scheduled_for&.iso8601,
          },
        )
      end
  end
end
