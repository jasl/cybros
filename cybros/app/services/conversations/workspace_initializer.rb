require "fileutils"

module Conversations
  class WorkspaceInitializer
    SAFE_LOGICAL_WORKSPACE_KEY = /\A[a-zA-Z0-9._-]+\z/.freeze

    def self.initialize!(conversation:)
      new(conversation: conversation).initialize!
    end

    def initialize(conversation:)
      @conversation = conversation
    end

    def initialize!
      conversation.with_lock do
        conversation.reload
        return workspace_snapshot if conversation.logical_workspace_initialized?

        logical_workspace_key = normalized_logical_workspace_key
        conversations_root_path = RuntimeSetting.instance_agent_workspace_root_path.join("conversations").cleanpath
        logical_workspace_directory_name = ActiveStorage::Filename.new(logical_workspace_key).sanitized
        logical_workspace_root_path = conversations_root_path.join(logical_workspace_directory_name).cleanpath

        conversations_root_path.mkpath
        logical_workspace_root_path.mkpath

        conversation.update!(
          logical_workspace_key: logical_workspace_key,
          logical_workspace_root_path: logical_workspace_root_path.to_s,
          logical_workspace_initialized_at: conversation.logical_workspace_initialized_at || Time.current.change(usec: 0),
        )

        workspace_snapshot
      end
    end

    private

      attr_reader :conversation

      def workspace_snapshot
        {
          logical_workspace_key: conversation.logical_workspace_key,
          logical_workspace_root_path: conversation.logical_workspace_root_path,
          logical_workspace_initialized_at: conversation.logical_workspace_initialized_at,
        }
      end

      def normalized_logical_workspace_key
        raw_key = conversation.logical_workspace_key.to_s.strip
        return raw_key if raw_key.match?(SAFE_LOGICAL_WORKSPACE_KEY) && !%w[. ..].include?(raw_key)

        "conversation-#{conversation.id}"
      end
  end
end
