module Cybros
  module ProgrammableAgent
    class ToolExecution
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

        AgentRPC::LifecycleCaller.call!(
          deployment: conversation_run.agent_deployment,
          conversation: conversation_run.conversation,
          scope_type: "conversation_run",
          scope_id: conversation_run.id,
          method_name: "tool.execute",
          invocation_id: invocation_id,
          request_payload: request_payload,
          allowed_callback_methods: [],
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
          {
            "tool_call_id" => tool_call_id,
            "logical_tool_name" => logical_tool_name,
            "effective_tool_id" => effective_tool_id,
            "implementation_source" => "agent_program",
            "implementation_ref" => implementation_ref,
            "capability_registry_snapshot_id" => capability_registry_snapshot_id,
            "tool_surface_id" => tool_surface_id,
            "arguments" => arguments,
          }
        end
    end
  end
end
