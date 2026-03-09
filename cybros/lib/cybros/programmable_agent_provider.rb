module Cybros
  class ProgrammableAgentProvider < AgentCore::Resources::Provider::Base
    CALLBACK_METHODS = [].freeze

    attr_reader :conversation_run

    def initialize(conversation_run:)
      @conversation_run = conversation_run
      @last_call_metadata = {}
    end

    def chat(messages:, model:, tools: nil, stream: false, **options)
      result = invoke_turn_compose(messages:, model:, tools:, options:)
      response = build_response(result)
      set_last_call_metadata!("turn.compose")
      stream ? stream_response(response) : response
    rescue AgentCore::ValidationError
      raise
    rescue StandardError => e
      response = response_from_error_hook(messages:, model:, tools:, options:, error: e)
      set_last_call_metadata!("turn.handle_error")
      stream ? stream_response(response) : response
    end

    def name = "programmable_agent"
    def provider_key = "programmable_agent"
    def model_ref = conversation_run.selected_model_ref.to_s
    def api_model = model_ref.split("/", 2).last.to_s.presence || conversation_run.selected_model_ref.to_s
    def last_call_metadata = @last_call_metadata

    private

      def invoke_turn_compose(messages:, model:, tools:, options:)
        AgentRpc::LifecycleCaller.call!(
          deployment: conversation_run.agent_deployment,
          conversation: conversation_run.conversation,
          scope_type: "conversation_run",
          scope_id: conversation_run.id,
          method_name: "turn.compose",
          invocation_id: conversation_run.compose_invocation_id,
          request_payload: request_payload(messages:, model:, tools:, options:),
          allowed_callback_methods: CALLBACK_METHODS,
        )
      end

      def invoke_turn_handle_error(messages:, model:, tools:, options:, error:)
        AgentRpc::LifecycleCaller.call!(
          deployment: conversation_run.agent_deployment,
          conversation: conversation_run.conversation,
          scope_type: "conversation_run",
          scope_id: conversation_run.id,
          method_name: "turn.handle_error",
          invocation_id: conversation_run.handle_error_invocation_id,
          request_payload: request_payload(messages:, model:, tools:, options:).merge("error" => error_payload(error)),
          allowed_callback_methods: CALLBACK_METHODS,
        )
      end

      def request_payload(messages:, model:, tools:, options:)
        {
          "conversation_run_id" => conversation_run.id,
          "conversation_id" => conversation_run.conversation_id,
          "dag_node_id" => conversation_run.dag_node_id,
          "selected_model_ref" => conversation_run.selected_model_ref,
          "effective_permission_mode" => conversation_run.effective_permission_mode,
          "execution_target_id" => conversation_run.execution_target_id,
          "prepared_plan" => conversation_run.snapshot.dig("draft", "prepared_plan"),
          "approval_state" => conversation_run.snapshot.dig("draft", "approval_state"),
          "provider_input" => {
            "model" => model.to_s,
            "messages" => Array(messages).map { |message| message.respond_to?(:to_h) ? AgentCore::Utils.deep_stringify_keys(message.to_h) : message },
            "tools" => AgentCore::Utils.deep_stringify_keys(Array(tools)),
            "options" => AgentCore::Utils.deep_stringify_keys(options),
          },
          "run_snapshot" => {
            "snapshot_version" => conversation_run.snapshot_version,
            "agent_program_id" => conversation_run.agent_program_id,
            "contract_fingerprint" => conversation_run.contract_fingerprint,
            "agent_deployment_id" => conversation_run.agent_deployment_id,
            "deployment_fingerprint" => conversation_run.deployment_fingerprint,
            "deployment_activated_at" => conversation_run.deployment_activated_at&.iso8601,
            "provider_credential_id" => conversation_run.provider_credential_id,
            "runtime_governors" => conversation_run.runtime_governors,
            "effective_public_settings" => conversation_run.effective_public_settings,
            "effective_agent_config" => conversation_run.effective_agent_config,
            "effective_policy" => conversation_run.effective_policy,
          },
        }.compact
      end

      def build_response(result)
        payload = result.is_a?(Hash) ? result.deep_stringify_keys : {}
        output = payload["output"]

        message =
          case output
          when Hash
            AgentCore::Message.from_h(output.reverse_merge("role" => "assistant"))
          when String
            AgentCore::Message.new(role: :assistant, content: output)
          else
            AgentCore::ValidationError.raise!(
              "turn.compose must return an assistant output payload.",
              code: "cybros.programmable_agent.turn_compose_invalid_output",
              details: { conversation_run_id: conversation_run.id },
            )
          end

        AgentCore::Resources::Provider::Response.new(
          message: message,
          usage: build_usage(payload["usage"]),
          raw: payload,
          stop_reason: normalize_stop_reason(payload["stop_reason"]),
        )
      end

      def response_from_error_hook(messages:, model:, tools:, options:, error:)
        result = invoke_turn_handle_error(messages:, model:, tools:, options:, error: error)
        build_response(result)
      rescue AgentCore::ValidationError
        raise
      rescue StandardError
        raise AgentCore::ProviderError.new(error.message)
      end

      def set_last_call_metadata!(method_name)
        @last_call_metadata = {
          "agent_rpc" => {
            "method" => method_name,
            "scope_type" => "conversation_run",
            "scope_id" => conversation_run.id,
          },
        }
      end

      def stream_response(response)
        message = response.message
        usage = response.usage
        Enumerator.new do |y|
          text = message.text.to_s
          y << AgentCore::StreamEvent::TextDelta.new(text: text) unless text.empty?
          y << AgentCore::StreamEvent::MessageComplete.new(message: message)
          y << AgentCore::StreamEvent::Done.new(stop_reason: response.stop_reason, usage: usage)
        end
      end

      def error_payload(error)
        {
          "class" => error.class.name,
          "message" => error.message.to_s,
        }.compact
      end

      def build_usage(value)
        return nil unless value.is_a?(Hash)

        usage = value.deep_stringify_keys
        AgentCore::Resources::Provider::Usage.new(
          input_tokens: usage["input_tokens"].to_i,
          output_tokens: usage["output_tokens"].to_i,
          cache_creation_tokens: usage["cache_creation_tokens"].to_i,
          cache_read_tokens: usage["cache_read_tokens"].to_i,
        )
      end

      def normalize_stop_reason(value)
        reason = value.to_s.strip
        return :end_turn if reason.empty?

        reason.to_sym
      rescue StandardError
        :end_turn
      end
  end
end
