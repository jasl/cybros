module Cybros
  module Attachments
    module Tools
      module_function

      def build
        [build_transfer_tool]
      end

      def build_transfer_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "transfer_attachments",
          description: "Transfer conversation attachments into agent-consumable references.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "conversation_id" => { type: "string" },
              "attachment_ids" => {
                type: "array",
                items: { type: "string" },
                minItems: 1,
                uniqueItems: true,
              },
            },
            required: ["attachment_ids"],
          },
          metadata: { source: :cybros, category: :attachments, permission_class: "write", execution_mode: "serial" },
        ) do |args, context:|
          task_node = current_task_node!(context)
          conversation = conversation_for!(task_node: task_node, conversation_id: args["conversation_id"])
          conversation_run = conversation_run_for(task_node: task_node)
          transfer =
            Conversations::AttachmentTransferService.transfer!(
              conversation: conversation,
              attachment_ids: args["attachment_ids"],
              agent: conversation_run&.agent || conversation.agent,
              recognized_deployment: conversation_run&.recognized_deployment,
            )

          imports = transfer.fetch("imports")
          AgentCore::Resources::Tools::ToolResult.success(
            text: "Transferred #{imports.length} attachment(s).",
            metadata: transfer.merge(
              "conversation_id" => conversation.id,
              "attachment_ids" => imports.map { |entry| entry.fetch("id") },
            ),
          )
        rescue Conversations::AttachmentTransferService::TransferError => e
          AgentCore::Resources::Tools::ToolResult.error(
            text: e.message,
            metadata:
              AgentCore::Resources::Tools::ToolResult.with_tool_execution_metadata(
                {
                  "conversation_id" => conversation&.id,
                  "attachment_ids" => Array(args["attachment_ids"]).map(&:to_s),
                  "transfer_error" => {
                    "details" => AgentCore::Utils.deep_stringify_keys(e.details),
                  },
                },
                failure_class: e.failure_class,
                failure_code: e.code,
                retryable: e.retryable,
              ),
          )
        end
      end
      private_class_method :build_transfer_tool

      def current_task_node!(context)
        node_id = context&.attributes&.dig(:dag, :node_id).to_s
        node = DAG::Node.find_by(id: node_id)
        return node if node

        AgentCore::ValidationError.raise!(
          "attachment tools require a current DAG task node",
          code: "cybros.attachments.current_task_node_required",
        )
      end
      private_class_method :current_task_node!

      def conversation_for!(task_node:, conversation_id:)
        conversation = task_node.lane&.attachable
        conversation = task_node.graph.attachable unless conversation.is_a?(Conversation)
        unless conversation.is_a?(Conversation)
          AgentCore::ValidationError.raise!(
            "attachment tools require a Conversation-backed DAG graph",
            code: "cybros.attachments.conversation_required",
            details: { attachable_type: task_node.graph.attachable_type.to_s },
          )
        end

        expected_id = conversation_id.to_s.presence
        if expected_id.present? && expected_id != conversation.id.to_s
          AgentCore::ValidationError.raise!(
            "attachment tool conversation_id is invalid",
            code: "cybros.attachments.conversation_id_invalid",
            details: { conversation_id: expected_id, expected_conversation_id: conversation.id.to_s },
          )
        end

        conversation
      end
      private_class_method :conversation_for!

      def conversation_run_for(task_node:)
        ConversationRun.latest_for_node(task_node)
      rescue StandardError
        nil
      end
      private_class_method :conversation_run_for
    end
  end
end
