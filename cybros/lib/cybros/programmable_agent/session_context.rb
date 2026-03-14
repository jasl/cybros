module Cybros
  module ProgrammableAgent
    SessionContext =
      Data.define(
        :account_id,
        :user_id,
        :conversation_id,
        :workspace,
      ) do
        def self.from_conversation(conversation)
          new(
            account_id: Account.instance.id,
            user_id: conversation.user_id,
            conversation_id: conversation.id,
            workspace: workspace_payload_for(conversation),
          )
        end

        def to_h
          payload = {
            "account_id" => account_id,
            "user_id" => user_id,
            "conversation_id" => conversation_id,
          }
          payload["workspace"] = workspace if workspace.present?
          payload
        end

        class << self
          private

            def workspace_payload_for(conversation)
              return nil unless conversation&.logical_workspace_initialized?

              {
                "conversation_id" => conversation.id,
                "logical_workspace_key" => conversation.logical_workspace_key,
                "logical_workspace_root_path" => conversation.logical_workspace_root_path,
                "logical_workspace_initialized_at" => conversation.logical_workspace_initialized_at&.iso8601,
              }.compact
            end
        end
      end
  end
end
