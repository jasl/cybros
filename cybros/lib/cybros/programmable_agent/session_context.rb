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
              return nil if conversation.nil?

              conversation.workspace_payload
            end
        end
      end
  end
end
