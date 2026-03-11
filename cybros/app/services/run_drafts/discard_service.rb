module RunDrafts
  class DiscardService
    def self.discard!(draft:, status:, approval_state: nil)
      new(draft: draft, status: status, approval_state: approval_state).discard!
    end

    def initialize(draft:, status:, approval_state:)
      @draft = draft
      @status = status.to_s
      @approval_state = approval_state.is_a?(Hash) ? approval_state.deep_stringify_keys : nil
    end

    def discard!
      draft.with_lock do
        attributes = {
          status: status,
          runtime_governors: preserved_runtime_governors,
          staged_public_settings_patch: {},
          staged_agent_config_patch: {},
          staged_kv_ops: [],
          staged_prompt_buffer_ops: [],
        }
        attributes[:approval_state] = approval_state if approval_state.present?
        draft.update!(attributes)
      end
    end

    private

      attr_reader :draft, :status, :approval_state

      def preserved_runtime_governors
        draft.runtime_governors.is_a?(Hash) ? draft.runtime_governors.deep_dup : {}
      end
  end
end
