module Cybros
  module ProgrammableAgent
    class HookCaller
      def self.call!(
        deployment:,
        conversation:,
        scope_type:,
        scope_id:,
        hook_name:,
        invocation_id:,
        request_payload:,
        allowed_callback_methods:
      )
        AgentRPC::LifecycleCaller.call!(
          deployment: deployment,
          conversation: conversation,
          scope_type: scope_type,
          scope_id: scope_id,
          method_name: hook_name.to_s,
          invocation_id: invocation_id,
          request_payload: request_payload,
          allowed_callback_methods: allowed_callback_methods,
          result_validator: lambda do |result|
            HookEnvelope.parse!(
              hook_name: hook_name,
              request_payload: request_payload,
              payload: result,
            )
          end,
        )
      end
    end
  end
end
