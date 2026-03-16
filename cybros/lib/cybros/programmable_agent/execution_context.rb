module Cybros
  module ProgrammableAgent
    ExecutionContext =
      Data.define(
        :account_id,
        :user_id,
        :conversation_id,
        :graph_id,
        :lane_id,
        :turn_id,
        :dag_node_id,
        :execution_scope,
        :subagent,
        :workspace,
      ) do
        PRIMARY_SCOPE = "primary"
        SUBAGENT_SCOPE = "subagent"

        def self.from_conversation_node(conversation:, node:)
          scope = scope_attributes_for(conversation: conversation)

          new(
            account_id: Account.instance.id,
            user_id: conversation.user_id,
            conversation_id: conversation.id,
            graph_id: node.graph_id,
            lane_id: node.lane_id,
            turn_id: node.turn_id,
            dag_node_id: node.id,
            execution_scope: scope.fetch(:execution_scope),
            subagent: scope[:subagent],
            workspace: workspace_payload_for(conversation, lane_id: node.lane_id),
          )
        end

        def self.from_conversation_step(conversation:, dag_node_id:, node: nil)
          graph = conversation.root_graph
          lane = node&.lane || conversation.chat_lane
          scope = scope_attributes_for(conversation: conversation)

          new(
            account_id: Account.instance.id,
            user_id: conversation.user_id,
            conversation_id: conversation.id,
            graph_id: node&.graph_id || graph.id,
            lane_id: node&.lane_id || lane&.id,
            turn_id: node&.turn_id,
            dag_node_id: node&.id || dag_node_id,
            execution_scope: scope.fetch(:execution_scope),
            subagent: scope[:subagent],
            workspace: workspace_payload_for(conversation, lane_id: node&.lane_id || lane&.id),
          )
        end

        def to_h
          payload = {
            "account_id" => account_id,
            "user_id" => user_id,
            "conversation_id" => conversation_id,
            "graph_id" => graph_id,
            "lane_id" => lane_id,
            "turn_id" => turn_id,
            "dag_node_id" => dag_node_id,
            "execution_scope" => execution_scope,
            "subagent" => subagent,
            "workspace" => workspace,
          }
          payload.delete("subagent") if subagent.nil?
          payload.delete("workspace") if workspace.nil?
          payload
        end

        class << self
          private

            def scope_attributes_for(conversation:)
              subagent_payload = subagent_payload_for(conversation: conversation)

              {
                execution_scope: subagent_payload.present? ? SUBAGENT_SCOPE : PRIMARY_SCOPE,
                subagent: subagent_payload,
              }
            end

            def subagent_payload_for(conversation:)
              metadata = conversation.metadata.is_a?(Hash) ? conversation.metadata.deep_stringify_keys : {}
              subagent = metadata["subagent"]
              return nil unless subagent.is_a?(Hash)

              subagent_id = subagent["subagent_id"].to_s.strip
              return nil if subagent_id.empty?

              parent_dag_node_id =
                subagent["parent_dag_node_id"].to_s.strip.presence ||
                  subagent["spawned_from_node_id"].to_s.strip.presence

              parent_turn_id =
                subagent["parent_turn_id"].to_s.strip.presence ||
                  derive_parent_turn_id(conversation: conversation, metadata: subagent, parent_dag_node_id: parent_dag_node_id)

              depth = Integer(subagent["depth"], exception: false)

              {
                "subagent_id" => subagent_id,
                "parent_turn_id" => parent_turn_id,
                "parent_dag_node_id" => parent_dag_node_id,
                "depth" => depth,
              }.compact
            end

            def derive_parent_turn_id(conversation:, metadata:, parent_dag_node_id:)
              return nil if parent_dag_node_id.blank?

              parent =
                conversation.parent_conversation ||
                  Conversation.find_by(id: metadata["parent_conversation_id"].to_s.presence)
              parent&.turn_id_for_node_id(parent_dag_node_id)
            rescue StandardError
              nil
            end

            def workspace_payload_for(conversation, lane_id:)
              return nil if conversation.nil?

              conversation.workspace_payload(lane_id: lane_id)
            end
        end
      end
  end
end
