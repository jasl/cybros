module Cybros
  module ProgrammableAgent
    class ToolExecution
      TOOL_EXECUTE_CALLBACK_METHODS = %w[
        conversation.memory.get
        conversation.memory.put
        conversation.memory.append
      ].freeze

      def self.call!(
        conversation_run:,
        tool_call_id:,
        logical_tool_name:,
        effective_tool_id:,
        implementation_ref:,
        capability_registry_snapshot_id:,
        tool_surface_id:,
        arguments:
      )
        new(
          conversation_run: conversation_run,
          tool_call_id: tool_call_id,
          logical_tool_name: logical_tool_name,
          effective_tool_id: effective_tool_id,
          implementation_ref: implementation_ref,
          capability_registry_snapshot_id: capability_registry_snapshot_id,
          tool_surface_id: tool_surface_id,
          arguments: arguments,
        ).call!
      end

      def initialize(
        conversation_run:,
        tool_call_id:,
        logical_tool_name:,
        effective_tool_id:,
        implementation_ref:,
        capability_registry_snapshot_id:,
        tool_surface_id:,
        arguments:
      )
        @conversation_run = conversation_run
        @tool_call_id = tool_call_id.to_s
        @logical_tool_name = logical_tool_name.to_s
        @effective_tool_id = effective_tool_id.to_s
        @implementation_ref = implementation_ref.to_s
        @capability_registry_snapshot_id = capability_registry_snapshot_id.to_s
        @tool_surface_id = tool_surface_id.to_s
        @arguments = AgentCore::Utils.deep_stringify_keys(arguments.is_a?(Hash) ? arguments : {})
      end

      def call!
        AgentCore::ValidationError.raise!(
          "conversation_run is required for programmable agent tool execution",
          code: "cybros.programmable_agent.tool_execution.conversation_run_required",
        ) if conversation_run.nil?

        deployment = conversation_run.agent&.active_runtime_binding
        AgentCore::ValidationError.raise!(
          "conversation_run is missing its active agent runtime binding",
          code: "cybros.programmable_agent.tool_execution.runtime_binding_required",
          details: { conversation_run_id: conversation_run.id, agent_id: conversation_run.agent_id },
        ) if deployment.nil?

        AgentRPC::LifecycleCaller.call!(
          deployment: deployment,
          conversation: conversation_run.conversation,
          scope_type: "conversation_run",
          scope_id: conversation_run.id,
          method_name: "tool.execute",
          invocation_id: invocation_id,
          request_payload: request_payload,
          allowed_callback_methods: TOOL_EXECUTE_CALLBACK_METHODS,
        )
      end

      private

        attr_reader :conversation_run, :tool_call_id, :logical_tool_name, :effective_tool_id,
          :implementation_ref, :capability_registry_snapshot_id, :tool_surface_id, :arguments

        def invocation_id
          suffix = tool_call_id.presence || effective_tool_id
          "conversation_run:#{conversation_run.id}:tool.execute:#{suffix}"
        end

        def request_payload
          payload = {
            "tool_call_id" => tool_call_id,
            "logical_tool_name" => logical_tool_name,
            "effective_tool_id" => effective_tool_id,
            "implementation_source" => "agent",
            "implementation_ref" => implementation_ref,
            "capability_registry_snapshot_id" => capability_registry_snapshot_id,
            "tool_surface_id" => tool_surface_id,
            "arguments" => arguments,
          }

          if (context_payload = conversation_context_payload).present?
            payload.merge!(context_payload)
          end

          payload
        end

        def conversation_context_payload
          conversation = conversation_run.conversation
          return {} unless conversation.present?

          {
            "session_context" => SessionContext.from_conversation(conversation).to_h,
            "execution_context" => execution_context_for(conversation).to_h,
          }
        rescue StandardError
          {}
        end

        def execution_context_for(conversation)
          node = conversation.root_graph.nodes.find_by(id: conversation_run.dag_node_id)
          return ExecutionContext.from_conversation_node(conversation: conversation, node: node) if node.present?

          ExecutionContext.from_conversation_step(
            conversation: conversation,
            dag_node_id: conversation_run.dag_node_id,
          )
        end
    end
  end
end
