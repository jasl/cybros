module Cybros
  module ProgrammableAgent
    SessionContext =
      Data.define(
        :account_id,
        :user_id,
        :conversation_id,
      ) do
        def self.from_conversation(conversation)
          new(
            account_id: Account.instance.id,
            user_id: conversation.user_id,
            conversation_id: conversation.id,
          )
        end

        def to_h
          {
            "account_id" => account_id,
            "user_id" => user_id,
            "conversation_id" => conversation_id,
          }
        end
      end
  end
end
