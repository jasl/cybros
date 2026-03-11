module Cybros
  class ProgrammableAgentProvider < AgentCore::Resources::Provider::Base
    CALLBACK_METHODS = %w[tool_surface.manifest].freeze

    attr_reader :conversation_run, :delegate

    def initialize(conversation_run:, delegate:)
      @conversation_run = conversation_run
      @delegate = delegate
      @last_call_metadata = {}
    end

    def chat(messages:, model:, tools: nil, stream: false, **options)
      response = delegate.chat(messages: messages, model: model, tools: tools, stream: stream, **options)
      set_delegate_call_metadata!
      response
    end

    def name = "programmable_agent"
    def provider_key = "programmable_agent"
    def model_ref = conversation_run.selected_model_ref.to_s
    def api_model = delegate.respond_to?(:api_model) ? delegate.api_model : model_ref.split("/", 2).last.to_s.presence || model_ref
    def delegate_name = delegate.respond_to?(:name) ? delegate.name : delegate.class.name
    def last_call_metadata = @last_call_metadata

    def execute_programmable_tool!(**payload)
      Cybros::ProgrammableAgent::ToolExecution.call!(
        conversation_run: conversation_run,
        **payload,
      )
    end

    def run_before_finalize_output!(node:, built_prompt:, draft_output:)
      envelope =
        invoke_hook!(
          hook_name: "before_finalize_output",
          invocation_id: conversation_run.before_finalize_output_invocation_id(node: node),
          request_payload: hook_request_payload(node: node, built_prompt: built_prompt).merge(
            "draft_output" => AgentCore::Utils.deep_stringify_keys(draft_output),
          ),
        )

      execute_hook_actions!(hook_name: "before_finalize_output", envelope: envelope, placeholder_node: node)
    end

    def run_on_context_pressure!(node:, built_prompt:, context_pressure:)
      envelope =
        invoke_hook!(
          hook_name: "on_context_pressure",
          invocation_id: conversation_run.on_context_pressure_invocation_id(node: node),
          request_payload: hook_request_payload(node: node, built_prompt: built_prompt).merge(
            "context_pressure" => AgentCore::Utils.deep_stringify_keys(context_pressure),
          ),
        )

      execute_hook_actions!(
        hook_name: "on_context_pressure",
        envelope: envelope,
        placeholder_node: node,
        anchor_node: node,
      )
    end

    def run_before_subagent_spawn!(node:, subagent_request:)
      envelope =
        invoke_hook!(
          hook_name: "before_subagent_spawn",
          invocation_id: conversation_run.before_subagent_spawn_invocation_id(node: node),
          request_payload: hook_request_payload(node: node, built_prompt: nil).merge(
            "subagent_request" => AgentCore::Utils.deep_stringify_keys(subagent_request),
          ),
        )

      execute_hook_actions!(
        hook_name: "before_subagent_spawn",
        envelope: envelope,
        placeholder_node: placeholder_node_for_runtime_hook(node),
        anchor_node: node,
      )
    end

    def run_after_task_notice!(node:, built_prompt:, notice_kind:, error:, status: "failed", subject_kind: nil, logical_tool_name: nil, artifacts: nil, retryable: nil, user_decision_required: nil)
      envelope =
        invoke_hook!(
          hook_name: "after_task_notice",
          invocation_id: conversation_run.after_task_notice_invocation_id(node: node),
          request_payload: hook_request_payload(node: node, built_prompt: built_prompt).merge(
            "task_notice" => task_notice_payload(
              task_id: node.id,
              status: status,
              subject_kind: subject_kind,
              notice_kind: notice_kind,
              error: error,
              logical_tool_name: logical_tool_name,
              artifacts: artifacts,
              retryable: retryable,
              user_decision_required: user_decision_required,
            ),
          ),
        )

      execute_hook_actions!(
        hook_name: "after_task_notice",
        envelope: envelope,
        placeholder_node: placeholder_node_for_runtime_hook(node),
        anchor_node: node,
      )
    end

    def run_after_subagent_result!(node:, subagent_result:)
      envelope =
        invoke_hook!(
          hook_name: "after_subagent_result",
          invocation_id: conversation_run.after_subagent_result_invocation_id(node: node),
          request_payload: hook_request_payload(node: node, built_prompt: nil).merge(
            "subagent_result" => AgentCore::Utils.deep_stringify_keys(subagent_result),
          ),
        )

      execute_hook_actions!(
        hook_name: "after_subagent_result",
        envelope: envelope,
        placeholder_node: placeholder_node_for_runtime_hook(node),
        anchor_node: node,
      )
    end

    private

      def invoke_hook!(hook_name:, invocation_id:, request_payload:)
        Cybros::ProgrammableAgent::HookCaller.call!(
          deployment: conversation_run.agent_deployment,
          conversation: conversation_run.conversation,
          scope_type: "conversation_run",
          scope_id: conversation_run.id,
          hook_name: hook_name,
          invocation_id: invocation_id,
          request_payload: request_payload,
          allowed_callback_methods: CALLBACK_METHODS,
        )
      end

      def execute_hook_actions!(hook_name:, envelope:, placeholder_node:, anchor_node: nil)
        Cybros::ProgrammableAgent::HookActionExecutor.execute!(
          hook_name: hook_name,
          conversation_run: conversation_run,
          actions: envelope.actions,
          placeholder_node: placeholder_node,
          anchor_node: anchor_node,
        )
      end

      def placeholder_node_for_runtime_hook(node)
        conversation_run.conversation.root_graph.nodes.find_by(id: conversation_run.dag_node_id) || node
      end

      def hook_request_payload(node:, built_prompt:)
        conversation = conversation_run.conversation
        {
          "conversation_run_id" => conversation_run.id,
          "conversation_id" => conversation_run.conversation_id,
          "dag_node_id" => node.id,
          "capability_registry_snapshot_id" => capability_registry_snapshot_id,
          "session_context" => Cybros::ProgrammableAgent::SessionContext.from_conversation(conversation).to_h,
          "execution_context" => Cybros::ProgrammableAgent::ExecutionContext.from_conversation_node(
            conversation: conversation,
            node: node,
          ).to_h,
          "selected_model_ref" => conversation_run.selected_model_ref,
          "effective_permission_mode" => conversation_run.effective_permission_mode,
          "execution_target_id" => conversation_run.execution_target_id,
          "planning" => conversation_run.snapshot.dig("draft", "planning"),
          "approval_state" => conversation_run.snapshot.dig("draft", "approval_state"),
          "provider_input" => provider_input_payload(built_prompt),
          "run_snapshot" => run_snapshot_payload,
        }.compact
      end

      def provider_input_payload(built_prompt)
        prompt = built_prompt
        return nil unless prompt

        {
          "model" => api_model.to_s,
          "system_prompt" => prompt.respond_to?(:system_prompt) ? prompt.system_prompt.to_s : "",
          "messages" => Array(prompt.respond_to?(:messages) ? prompt.messages : []).map { |message| normalize_message(message) },
          "tools" => AgentCore::Utils.deep_stringify_keys(Array(prompt.respond_to?(:tools) ? prompt.tools : [])),
          "options" => AgentCore::Utils.deep_stringify_keys(prompt.respond_to?(:options) ? prompt.options : {}),
        }
      end

      def normalize_message(message)
        return AgentCore::Utils.deep_stringify_keys(message.to_h) if message.respond_to?(:to_h)

        message
      end

      def run_snapshot_payload
        {
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
        }
      end

      def set_delegate_call_metadata!
        metadata =
          if delegate.respond_to?(:last_call_metadata)
            AgentCore::Utils.deep_stringify_keys(delegate.last_call_metadata)
          else
            {}
          end

        metadata["delegate_name"] = delegate_name
        tool_surface = conversation_run.snapshot.dig("draft", "planning", "tool_surface")
        metadata["tool_surface"] = AgentCore::Utils.deep_stringify_keys(tool_surface) if tool_surface.is_a?(Hash)
        @last_call_metadata = metadata
      rescue StandardError
        @last_call_metadata = { "delegate_name" => delegate_name }
      end

      def error_payload(error)
        {
          "class" => error.class.name,
          "message" => error.message.to_s,
          "status" => (error.respond_to?(:status) ? error.status : nil),
          "code" => (error.respond_to?(:code) ? error.code : nil),
        }.compact
      end

      def task_notice_payload(task_id:, status:, subject_kind:, notice_kind:, error:, logical_tool_name:, artifacts:, retryable:, user_decision_required:)
        {
          "task_id" => task_id,
          "status" => status.to_s,
          "subject_kind" => subject_kind.to_s.presence,
          "notice" => {
            "kind" => notice_kind.to_s,
          },
          "logical_tool_name" => logical_tool_name.to_s.presence,
          "error" => error_payload(error),
          "artifacts" => Array(artifacts).presence,
          "retryable" => retryable,
          "user_decision_required" => user_decision_required,
        }.compact
      end

      def capability_registry_snapshot_id
        snapshot = conversation_run.snapshot.dig("capability_snapshot")
        snapshot = conversation_run.agent_deployment&.capability_snapshot unless snapshot.is_a?(Hash)
        snapshot = {} unless snapshot.is_a?(Hash)
        snapshot["capability_registry_snapshot_id"].to_s.presence
      end
  end
end
