module Conversations
  class WorkspaceInitializer
    def self.initialize!(conversation:)
      new(conversation: conversation).initialize!
    end

    def self.payload_for(conversation:, lane_id: nil)
      conversation.workspace_payload(lane_id: lane_id)
    end

    def self.conversation_path_for(conversation:)
      conversation.workspace_root_path
    end

    def self.lane_path_for(conversation:, lane_id:)
      conversation.lane_workspace_root_path(lane_id: lane_id).to_s
    end

    def self.materialize_conversation_directory!(conversation:)
      conversation_path = conversation_path_for(conversation: conversation)
      conversation_path.mkpath
      conversation_path
    end

    def self.materialize_lane_directory!(conversation:, lane_id:)
      lane_path = Pathname.new(lane_path_for(conversation: conversation, lane_id: lane_id))
      lane_path.mkpath
      lane_path
    end

    def initialize(conversation:)
      @conversation = conversation
    end

    def initialize!
        conversation.with_lock do
          conversation.reload

          agent_workspace = Agents::WorkspaceInitializer.initialize!(agent: conversation.agent)
          conversation_path = self.class.materialize_conversation_directory!(conversation: conversation)
          lane_path = self.class.materialize_lane_directory!(conversation: conversation, lane_id: conversation.chat_lane.id)

          conversation.update!(
            logical_workspace_key: "conversation-#{conversation.id}",
            logical_workspace_root_path: conversation_path.to_s,
            logical_workspace_initialized_at: conversation.logical_workspace_initialized_at || Time.current.change(usec: 0),
        )

        workspace_snapshot.merge(
          agent_root_path: agent_workspace.fetch(:root_path),
          root_path: agent_workspace.fetch(:root_path),
          conversation_path: conversation_path.to_s,
          lane_path: lane_path.to_s,
          cwd: conversation_path.to_s,
        )
      end
    end

    private

      attr_reader :conversation

      def workspace_snapshot
        {
          agent_root_path: Agents::WorkspaceInitializer.initialize!(agent: conversation.agent).fetch(:root_path),
          root_path: Agents::WorkspaceInitializer.initialize!(agent: conversation.agent).fetch(:root_path),
          conversation_path: self.class.conversation_path_for(conversation: conversation).to_s,
          lane_path: self.class.lane_path_for(conversation: conversation, lane_id: conversation.chat_lane.id),
          cwd: self.class.conversation_path_for(conversation: conversation).to_s,
          logical_workspace_key: conversation.logical_workspace_key,
          logical_workspace_root_path: conversation.logical_workspace_root_path,
          logical_workspace_initialized_at: conversation.logical_workspace_initialized_at,
        }
      end
  end
end
