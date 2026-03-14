require "uri"

module Cybros
  class ProgrammableAgentProvider < AgentCore::Resources::Provider::Base
    CALLBACK_METHODS = %w[tool_surface.manifest].freeze
    URL_MEDIA_SOURCE_SCHEMES = %w[http https].freeze
    URL_MEDIA_SOURCE_MUTEX = Mutex.new

    attr_reader :conversation_run, :delegate

    def initialize(conversation_run:, delegate:)
      @conversation_run = conversation_run
      @delegate = delegate
      @last_call_metadata = {}
    end

    def chat(messages:, model:, tools: nil, stream: false, **options)
      response =
        delegate.chat(
          messages: delegate_messages(messages: messages, node: runtime_chat_node),
          model: model,
          tools: tools,
          stream: stream,
          **options
        )
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
        deployment = conversation_run.agent&.active_runtime_binding
        AgentCore::ValidationError.raise!(
          "ConversationRun is missing its active agent runtime binding.",
          code: "cybros.programmable_agent_provider.runtime_binding_missing",
          details: {
            conversation_run_id: conversation_run.id,
            agent_id: conversation_run.agent_id,
            recognized_deployment_id: conversation_run.recognized_deployment_id,
          },
        ) if deployment.nil?

        Cybros::ProgrammableAgent::HookCaller.call!(
          deployment: deployment,
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
        graph = conversation_run.conversation.root_graph
        active_placeholder =
          graph.nodes.active
            .where(
              lane_id: node.lane_id,
              turn_id: node.turn_id,
              node_type: [
                Messages::AgentMessage.node_type_key,
                Messages::CharacterMessage.node_type_key,
              ],
            )
            .order(:id)
            .last

        active_placeholder || graph.nodes.find_by(id: conversation_run.dag_node_id) || node
      rescue StandardError
        conversation_run.conversation.root_graph.nodes.find_by(id: conversation_run.dag_node_id) || node
      end

      def hook_request_payload(node:, built_prompt:)
        conversation = conversation_run.conversation
        session_context = Cybros::ProgrammableAgent::SessionContext.from_conversation(conversation).to_h
        execution_context =
          Cybros::ProgrammableAgent::ExecutionContext.from_conversation_node(
            conversation: conversation,
            node: node,
          ).to_h
        {
          "conversation_run_id" => conversation_run.id,
          "conversation_id" => conversation_run.conversation_id,
          "dag_node_id" => node.id,
          "capability_registry_snapshot_id" => capability_registry_snapshot_id,
          "session_context" => session_context,
          "execution_context" => execution_context,
          "attachment_manifest" => attachment_manifest_for_node(node),
          "selected_model_ref" => conversation_run.selected_model_ref,
          "effective_permission_mode" => conversation_run.effective_permission_mode,
          "planning" => conversation_run.snapshot.dig("draft", "planning"),
          "approval_state" => conversation_run.snapshot.dig("draft", "approval_state"),
          "provider_input" => provider_input_payload(built_prompt, node: node),
          "run_snapshot" => run_snapshot_payload,
        }.compact
      end

      def provider_input_payload(built_prompt, node:)
        prompt = built_prompt
        return nil unless prompt

        augmented_messages =
          delegate_messages(
            messages: Array(prompt.respond_to?(:messages) ? prompt.messages : []),
            node: node,
          )

        {
          "model" => api_model.to_s,
          "system_prompt" => prompt.respond_to?(:system_prompt) ? prompt.system_prompt.to_s : "",
          "messages" => augmented_messages.map { |message| normalize_message(message) },
          "tools" => AgentCore::Utils.deep_stringify_keys(Array(prompt.respond_to?(:tools) ? prompt.tools : [])),
          "options" => AgentCore::Utils.deep_stringify_keys(prompt.respond_to?(:options) ? prompt.options : {}),
        }
      end

      def delegate_messages(messages:, node:)
        normalized = Array(messages).map { |message| normalize_message(message) }
        with_url_media_sources_allowed do
          inject_attachment_prompt_context(messages: normalized, node: node).map do |message|
            message.is_a?(AgentCore::Message) ? message : AgentCore::Message.from_h(message)
          end
        end
      rescue StandardError
        Array(messages)
      end

      def normalize_message(message)
        return AgentCore::Utils.deep_stringify_keys(message.to_h) if message.respond_to?(:to_h)

        message
      end

      def inject_attachment_prompt_context(messages:, node:)
        attachments = attachment_records_for_node(node)
        return messages if attachments.empty?

        user_index = messages.rindex { |message| message.is_a?(Hash) && message["role"].to_s == "user" }
        return messages if user_index.nil?

        augmented_messages = messages.map { |message| message.is_a?(Hash) ? message.deep_dup : message }
        augmented_messages[user_index] = augment_user_message_with_attachments(augmented_messages.fetch(user_index), attachments: attachments)
        augmented_messages
      rescue StandardError
        messages
      end

      def augment_user_message_with_attachments(message, attachments:)
        content_parts = normalize_content_parts(message["content"])
        attachment_text = attachment_prompt_text(attachments)
        content_parts << { "type" => "text", "text" => attachment_text } if attachment_text.present?

        if model_supports_images?
          attachment_image_blocks(attachments).each do |block|
            content_parts << block
          end
        end

        augmented = message.deep_dup
        augmented["content"] = content_parts
        augmented
      end

      def normalize_content_parts(content)
        case content
        when Array
          content.map do |block|
            if block.is_a?(Hash)
              AgentCore::Utils.deep_stringify_keys(block)
            elsif block.respond_to?(:to_h)
              AgentCore::Utils.deep_stringify_keys(block.to_h)
            else
              { "type" => "text", "text" => block.to_s }
            end
          end
        when String
          content.empty? ? [] : [{ "type" => "text", "text" => content }]
        when nil
          []
        else
          [{ "type" => "text", "text" => content.to_s }]
        end
      end

      def attachment_prompt_text(attachments)
        lines = attachments.each_with_index.map do |attachment, index|
          "Attachment #{index + 1}: #{attachment.filename} (#{attachment.content_type.presence || "application/octet-stream"})"
        end
        return nil if lines.empty?

        lines.join("\n")
      end

      def attachment_image_blocks(attachments)
        attachments.filter_map do |attachment|
          next unless image_attachment?(attachment)

          url = signed_download_url_for(attachment)
          next if url.blank?

          {
            "type" => "image",
            "source_type" => "url",
            "url" => url,
            "media_type" => attachment.content_type,
          }
        end
      end

      def attachment_manifest_for_node(node)
        attachment_records_for_node(node).map do |attachment|
          {
            "id" => attachment.id,
            "position" => attachment.position,
            "source_message_node_id" => attachment.source_message_node_id.to_s,
            "filename" => attachment.filename,
            "content_type" => attachment.content_type,
            "byte_size" => attachment.byte_size,
            "digest" => attachment.digest,
          }
        end
      rescue StandardError
        []
      end

      def attachment_records_for_node(node)
        turn_id = node&.turn_id.to_s.presence
        return [] if turn_id.blank?

        user_node =
          conversation_run.conversation.root_graph.nodes.active
            .where(turn_id: turn_id, node_type: Messages::UserMessage.node_type_key)
            .order(:id)
            .first
        return [] if user_node.nil?

        conversation_run.conversation.conversation_attachments
          .where(source_message_node_id: user_node.id)
          .includes(file_attachment: :blob)
          .order(:position, :id)
          .to_a
      rescue StandardError
        []
      end

      def image_attachment?(attachment)
        attachment.content_type.to_s.start_with?("image/")
      end

      def runtime_chat_node
        conversation_run.conversation.root_graph.nodes.active.find_by(id: conversation_run.dag_node_id)
      rescue StandardError
        nil
      end

      def with_url_media_sources_allowed
        URL_MEDIA_SOURCE_MUTEX.synchronize do
          config = AgentCore.config
          original_allow = config.allow_url_media_sources
          original_schemes = config.allowed_media_url_schemes&.dup

          AgentCore.configure do |agent_core_config|
            agent_core_config.allow_url_media_sources = true
            agent_core_config.allowed_media_url_schemes = original_schemes || URL_MEDIA_SOURCE_SCHEMES
          end

          yield
        ensure
          AgentCore.configure do |agent_core_config|
            agent_core_config.allow_url_media_sources = original_allow
            agent_core_config.allowed_media_url_schemes = original_schemes
          end
        end
      end

      def model_supports_images?
        provider_key, model_key = conversation_run.selected_model_ref.to_s.split("/", 2).map(&:to_s)
        return false if provider_key.blank? || model_key.blank?

        Cybros::LLM::Catalog.effective.model(provider_key, model_key).dig("capabilities", "input", "image") == true
      rescue StandardError
        false
      end

      def signed_download_url_for(attachment)
        Rails.application.routes.url_helpers.rails_blob_url(attachment.file, **download_url_options)
      rescue StandardError
        nil
      end

      def download_url_options
        @download_url_options ||= begin
          base_url = Current.base_url.presence || ENV["CYBROS_BASE_URL"].to_s.presence

          if base_url.present?
            uri = URI.parse(base_url)
            {
              protocol: uri.scheme,
              host: uri.host,
              port: default_port?(uri) ? nil : uri.port,
            }.compact
          else
            options = ActionMailer::Base.default_url_options || {}
            {
              protocol: options[:protocol].presence || options["protocol"].presence || "http",
              host: options[:host].presence || options["host"].presence,
              port: options[:port].presence || options["port"].presence,
            }.compact
          end
        end
      end

      def default_port?(uri)
        (uri.scheme == "http" && uri.port == 80) || (uri.scheme == "https" && uri.port == 443)
      end

      def run_snapshot_payload
        {
          "snapshot_version" => conversation_run.snapshot_version,
          "agent_id" => conversation_run.agent_id,
          "recognized_deployment_id" => conversation_run.recognized_deployment_id,
          "recognized_deployment_key" => conversation_run.recognized_deployment_key,
          "contract_fingerprint" => conversation_run.contract_fingerprint,
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
        snapshot = conversation_run.recognized_deployment&.capability_snapshot unless snapshot.is_a?(Hash)
        snapshot = {} unless snapshot.is_a?(Hash)
        snapshot["capability_registry_snapshot_id"].to_s.presence
      end
  end
end
