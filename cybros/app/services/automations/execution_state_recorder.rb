module Automations
  class ExecutionStateRecorder
    def self.attach_agent_node!(conversation:, dag_node_id:)
      new(conversation: conversation).record!(status: current_status(conversation), extra: { "dag_node_id" => dag_node_id })
    end

    def self.queued!(conversation:, initiated_by_user:, scheduled_for:, dispatch_key:)
      new(conversation: conversation).record!(
        status: "queued",
        extra: {
          "queued_at" => Time.current.change(usec: 0).iso8601,
          "scheduled_for" => scheduled_for&.iso8601,
          "dispatch_key" => dispatch_key,
          "initiated_by_user_id" => initiated_by_user&.id,
        }.compact,
      )
    end

    def self.planning!(conversation:)
      new(conversation: conversation).record!(
        status: "planning",
        extra: {
          "started_at" => Time.current.change(usec: 0).iso8601,
        },
      )
    end

    def self.awaiting_approval!(conversation:, draft:)
      new(conversation: conversation, draft: draft).record!(status: "awaiting_approval")
    end

    def self.running!(conversation:, draft: nil, conversation_run: nil)
      new(conversation: conversation, draft: draft, conversation_run: conversation_run).record!(status: "running")
    end

    def self.completed!(conversation:, draft: nil, conversation_run: nil)
      new(conversation: conversation, draft: draft, conversation_run: conversation_run).record!(status: "completed", finished: true)
    end

    def self.rejected!(conversation:, draft: nil)
      new(conversation: conversation, draft: draft).record!(status: "rejected", finished: true)
    end

    def self.canceled!(conversation:, draft: nil, conversation_run: nil)
      new(conversation: conversation, draft: draft, conversation_run: conversation_run).record!(status: "canceled", finished: true)
    end

    def self.failed!(conversation:, draft: nil, conversation_run: nil, error: nil, failure: nil)
      new(
        conversation: conversation,
        draft: draft,
        conversation_run: conversation_run,
        error: error,
        failure: failure,
      ).record!(status: "failed", finished: true)
    end

    def self.current_status(conversation)
      conversation.metadata.dig("automation_execution", "status").to_s.presence || "queued"
    end

    def initialize(conversation:, draft: nil, conversation_run: nil, error: nil, failure: nil)
      @conversation = conversation
      @draft = draft
      @conversation_run = conversation_run
      @error = error
      @failure = failure.is_a?(Hash) ? failure.deep_stringify_keys : nil
    end

    def record!(status:, finished: false, extra: {})
      conversation.with_lock do
        conversation.reload

        payload = current_payload.deep_merge(extra.deep_stringify_keys)
        payload["status"] = status
        payload["draft_id"] = draft.id if draft.present?
        payload["conversation_run_id"] = resolved_conversation_run&.id
        payload.delete("failure")
        payload["failure"] = failure_payload if failure_payload.present?
        payload["finished_at"] = Time.current.change(usec: 0).iso8601 if finished

        conversation.update!(metadata: conversation.metadata.deep_merge("automation_execution" => payload.compact))
      end

      conversation
    end

    private

      attr_reader :conversation, :draft, :conversation_run, :error

      def current_payload
        payload = conversation.metadata["automation_execution"]
        payload.is_a?(Hash) ? payload.deep_dup : {}
      end

      def resolved_conversation_run
        return conversation_run if conversation_run.present?
        return draft.materialized_conversation_run if draft&.materialized_conversation_run.present?

        nil
      end

      def failure_payload
        return @failure_payload if defined?(@failure_payload)
        return @failure_payload = @failure.deep_dup if @failure.present?
        return @failure_payload = nil if error.blank?

        payload = {
          "class" => error.class.name,
          "message" => error.message.to_s,
        }
        if error.respond_to?(:code)
          payload["code"] = error.code
          if error.respond_to?(:details) && error.details.present?
            payload["details"] =
              if error.details.is_a?(Hash)
                error.details.deep_stringify_keys
              else
                error.details
              end
          end
        end
        @failure_payload = payload.compact
      end
  end
end
