module Automations
  class RunStateRecorder
    def self.awaiting_approval!(automation_run:, draft:)
      new(automation_run: automation_run, draft: draft).record!(status: "awaiting_approval")
    end

    def self.running!(automation_run:, draft: nil)
      new(automation_run: automation_run, draft: draft).record!(status: "running")
    end

    def self.completed!(automation_run:, draft: nil)
      new(automation_run: automation_run, draft: draft).record!(status: "completed", finished: true)
    end

    def self.rejected!(automation_run: nil, draft: nil)
      automation_run ||= automation_run_for(draft)
      new(automation_run: automation_run, draft: draft).record!(status: "rejected", finished: true)
    end

    def self.canceled!(automation_run: nil, draft: nil)
      automation_run ||= automation_run_for(draft)
      new(automation_run: automation_run, draft: draft).record!(status: "canceled", finished: true)
    end

    def self.failed!(automation_run: nil, draft: nil, error: nil, failure: nil)
      automation_run ||= automation_run_for(draft)
      new(automation_run: automation_run, draft: draft, error: error, failure: failure).record!(status: "failed", finished: true)
    end

    def self.automation_run_for(draft)
      return nil if draft.blank?

      automation_run_id = draft.trigger_snapshot["automation_run_id"].to_s.strip
      return nil if automation_run_id.blank?

      AutomationRun.find_by(id: automation_run_id)
    end

    def initialize(automation_run:, draft:, error: nil, failure: nil)
      @automation_run = automation_run
      @draft = draft
      @error = error
      @failure = failure.is_a?(Hash) ? failure.deep_stringify_keys : nil
    end

    def record!(status:, finished: false)
      return automation_run if automation_run.blank?

      now = Time.current.change(usec: 0)
      attrs = {
        status: status,
        approval_state: approval_state_snapshot,
        snapshot: snapshot_payload,
      }
      attrs[:started_at] = automation_run.started_at || now
      attrs[:finished_at] = now if finished
      attrs[:conversation_run] = automation_run.conversation_run if automation_run.association(:conversation_run).loaded? || automation_run.conversation_run_id.present?
      automation_run.update!(attrs)
      automation_run
    end

    private

      attr_reader :automation_run, :draft, :error

      def approval_state_snapshot
        if draft.present? && draft.approval_state.is_a?(Hash)
          draft.approval_state.deep_stringify_keys
        elsif automation_run.approval_state.is_a?(Hash)
          automation_run.approval_state.deep_stringify_keys
        else
          {}
        end
      end

      def snapshot_payload
        snapshot = automation_run.snapshot.is_a?(Hash) ? automation_run.snapshot.deep_dup : {}
        snapshot = snapshot.deep_merge(draft_snapshot) if draft.present?
        snapshot = snapshot.deep_merge("runtime" => runtime_snapshot) if runtime_snapshot.present?
        snapshot["failure"] = failure_snapshot if failure_snapshot.present?
        snapshot
      end

      def draft_snapshot
        {
          "draft" => {
            "id" => draft.id,
            "status" => draft.status,
            "trigger_snapshot" => draft.trigger_snapshot,
            "prepared_plan" => draft.prepared_plan,
            "approval_state" => draft.approval_state,
          },
        }
      end

      def runtime_snapshot
        payload = {}

        if draft.present?
          payload.merge!(
            "conversation_id" => draft.conversation_id,
            "conversation_run_id" => automation_run.conversation_run_id,
            "selected_model_ref" => draft.selected_model_ref,
            "permission_mode" => draft.permission_mode,
            "agent_program_id" => draft.agent_program_id,
            "contract_fingerprint" => draft.contract_fingerprint,
            "agent_deployment_id" => draft.agent_deployment_id,
            "deployment_fingerprint" => draft.deployment_fingerprint,
            "deployment_activated_at" => draft.deployment_activated_at&.iso8601,
            "provider_credential_id" => draft.provider_credential_id,
            "execution_target_id" => draft.proposed_execution_target_id,
            "runtime_governors" => draft.runtime_governors,
          )
        end

        if automation_run.conversation_run.present?
          payload["conversation_id"] ||= automation_run.conversation_run.conversation_id
          payload["conversation_run_id"] = automation_run.conversation_run_id
        end

        payload.compact
      end

      def failure_snapshot
        return @failure_snapshot if defined?(@failure_snapshot)
        return @failure_snapshot = @failure.deep_dup if @failure.present?
        return @failure_snapshot = nil if error.blank?

        payload = {
          "class" => error.class.name,
          "message" => error.message.to_s,
        }
        if error.respond_to?(:code)
          payload["code"] = error.code
          payload["details"] = error.details if error.respond_to?(:details) && error.details.present?
        end
        @failure_snapshot = payload.compact
      end
  end
end
