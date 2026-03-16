require "fileutils"
require "uri"

module Conversations
  class AttachmentTransferService
    TransferError = Class.new(StandardError) do
      attr_reader :code, :failure_class, :retryable, :details

      def initialize(message, code:, failure_class:, retryable: true, details: {})
        @code = code.to_s
        @failure_class = failure_class.to_s
        @retryable = retryable
        @details = details || {}
        super(message)
      end
    end

    def self.transfer!(conversation:, attachment_ids: nil, agent: conversation.agent, recognized_deployment: nil)
      new(
        conversation: conversation,
        attachment_ids: attachment_ids,
        agent: agent,
        recognized_deployment: recognized_deployment,
      ).transfer!
    end

    def initialize(conversation:, attachment_ids:, agent:, recognized_deployment: nil)
      @conversation = conversation
      @attachment_ids = Array(attachment_ids).flatten.compact.map(&:to_s).reject(&:blank?)
      @recognized_deployment = recognized_deployment
      @agent = recognized_deployment&.agent || agent
    end

    def transfer!
      workspace = Conversations::WorkspaceInitializer.payload_for(conversation: conversation).deep_stringify_keys
      attachments = selected_attachments

      if bundled_claw_agent?
        {
          "transfer_mode" => "workspace_copy",
          "workspace" => workspace,
          "imports" => materialize_workspace_files!(attachments, workspace: workspace),
        }
      else
        {
          "transfer_mode" => "rpc_import",
          "workspace" => workspace,
          "imports" => import_remote_attachments!(attachments, workspace: workspace),
        }
      end
    end

    private

      attr_reader :conversation, :attachment_ids, :agent, :recognized_deployment

      def selected_attachments
        validate_attachment_ids!

        scope = conversation.conversation_attachments.includes(file_attachment: :blob).order(:position, :created_at)
        scope = scope.where(id: attachment_ids) if attachment_ids.any?
        attachments = scope.to_a

        if attachment_ids.any? && attachments.length != attachment_ids.length
          missing = attachment_ids - attachments.map { |attachment| attachment.id.to_s }
          AgentCore::ValidationError.raise!(
            "attachment_ids must belong to the current conversation",
            code: "cybros.conversations.attachment_transfer.attachments_must_belong_to_conversation",
            details: { conversation_id: conversation.id, missing_attachment_ids: missing },
          )
        end

        if attachments.empty?
          AgentCore::ValidationError.raise!(
            "attachment transfer requires at least one conversation attachment",
            code: "cybros.conversations.attachment_transfer.attachments_required",
            details: { conversation_id: conversation.id },
          )
        end

        if attachment_ids.any?
          attachments_by_id = attachments.index_by { |attachment| attachment.id.to_s }
          attachments = attachment_ids.map { |attachment_id| attachments_by_id.fetch(attachment_id) }
        end

        attachments
      end

      def validate_attachment_ids!
        duplicate_ids = attachment_ids.tally.select { |_id, count| count > 1 }.keys
        return if duplicate_ids.empty?

        AgentCore::ValidationError.raise!(
          "attachment_ids must be unique",
          code: "cybros.conversations.attachment_transfer.duplicate_attachment_ids",
          details: { conversation_id: conversation.id, duplicate_attachment_ids: duplicate_ids },
        )
      end

      def bundled_claw_agent?
        agent&.bundled_source? && agent&.bundled_agent_key.to_s == "claw"
      end

      def materialize_workspace_files!(attachments, workspace:)
        workspace_root = Conversations::WorkspaceInitializer.materialize_conversation_directory!(conversation: conversation)
        attachments_root = workspace_root.join("attachments")
        FileUtils.mkdir_p(attachments_root)

        attachments.map do |attachment|
          relative_path = File.join("attachments", "#{attachment.id}-#{sanitize_filename(attachment.filename)}")
          destination = workspace_root.join(relative_path)
          FileUtils.mkdir_p(destination.dirname)
          File.binwrite(destination, attachment.file.download)

          {
            "id" => attachment.id,
            "remote_ref" => {
              "kind" => "workspace_file",
              "path" => relative_path,
              "absolute_path" => destination.to_s,
              "filename" => attachment.filename,
              "content_type" => attachment.content_type,
              "byte_size" => attachment.byte_size,
              "digest" => attachment.digest,
            },
          }
        end
      rescue StandardError => e
        raise TransferError.new(
          "Attachment transfer into the conversation workspace failed: #{e.message}",
          code: "cybros.conversations.attachment_transfer.workspace_materialization_failed",
          failure_class: "implementation_error",
          details: { conversation_id: conversation.id },
        )
      end

      def import_remote_attachments!(attachments, workspace:)
        unless Agents::Protocol.attachment_import_supported?(supported_methods_for_transfer)
          AgentCore::ValidationError.raise!(
            "Selected agent does not support file attachments.",
            code: "cybros.conversations.attachment_transfer.agent_does_not_support_upload",
            details: { agent_id: agent&.id },
          )
        end

        descriptors = build_remote_descriptors(attachments, workspace: workspace)
        payload = Agents::Protocol.normalize_attachment_import_params!("attachments" => descriptors)
        result =
          Agents::RPCClient.new(
            agent: agent,
            recognized_deployment: recognized_deployment,
            deployment: deployment_for_transfer,
          ).call(Agents::Protocol::ATTACHMENT_IMPORT_METHOD, payload)

        normalize_remote_imports(result, expected_attachment_ids: attachments.map { |attachment| attachment.id.to_s })
      rescue AgentCore::ValidationError
        raise
      rescue Agents::RPCClient::TransportError => e
        raise TransferError.new(
          "Attachment transfer RPC failed: #{e.message}",
          code: "cybros.conversations.attachment_transfer.rpc_import_failed",
          failure_class: "remote_api_error",
          details: { agent_id: agent&.id, conversation_id: conversation.id },
        )
      end

      def supported_methods_for_transfer
        return [] if recognized_deployment.nil?

        Array(recognized_deployment.capability_snapshot.dig("observed_runtime_identity", "supported_methods")).presence ||
          Array(recognized_deployment.supported_methods)
      end

      def deployment_for_transfer
        @deployment_for_transfer ||= begin
          if recognized_deployment.blank?
            AgentCore::ValidationError.raise!(
              "Attachment transfer requires a pinned recognized deployment for external agents.",
              code: "cybros.conversations.attachment_transfer.recognized_deployment_required",
              details: { agent_id: agent&.id, conversation_id: conversation.id },
            )
          end

          runtime_binding = recognized_deployment&.agent&.active_runtime_binding || agent&.active_runtime_binding
          unless runtime_binding.present?
            AgentCore::ValidationError.raise!(
              "Attachment transfer requires a pinned recognized deployment for external agents.",
              code: "cybros.conversations.attachment_transfer.recognized_deployment_required",
              details: { agent_id: agent&.id, conversation_id: conversation.id },
            )
          end

          if runtime_binding.deployment_fingerprint.to_s != recognized_deployment.deployment_fingerprint.to_s
            AgentCore::ValidationError.raise!(
              "Pinned runtime identity changed during attachment transfer.",
              code: "cybros.conversations.attachment_transfer.recognized_deployment_drift",
              details: {
                agent_id: agent&.id,
                conversation_id: conversation.id,
                expected_recognized_deployment_key: recognized_deployment.recognized_deployment_key,
                current_deployment_fingerprint: runtime_binding.deployment_fingerprint,
                expected_deployment_fingerprint: recognized_deployment.deployment_fingerprint,
              },
            )
          end

          runtime_binding
        end
      end

      def build_remote_descriptors(attachments, workspace:)
        attachments.map do |attachment|
          {
            "id" => attachment.id,
            "filename" => attachment.filename,
            "content_type" => attachment.content_type,
            "byte_size" => attachment.byte_size,
            "digest" => attachment.digest,
            "signed_download_url" => signed_download_url_for(attachment),
            "conversation" => {
              "id" => conversation.id,
              "title" => conversation.title.to_s,
            },
            "workspace" => workspace.slice(
              "root_path",
              "conversation_path",
              "lane_path",
              "cwd",
            ),
          }
        end
      end

      def normalize_remote_imports(result, expected_attachment_ids:)
        imports = result.is_a?(Hash) ? Array(result["imports"]) : []
        if imports.empty?
          raise TransferError.new(
            "Attachment transfer RPC returned no imports.",
            code: "cybros.conversations.attachment_transfer.rpc_imports_missing",
            failure_class: "remote_api_error",
            details: { agent_id: agent&.id, conversation_id: conversation.id },
          )
        end

        normalized_imports = {}
        imports.each do |entry|
          normalized = entry.is_a?(Hash) ? entry.deep_stringify_keys : {}
          id = normalized.fetch("id").to_s
          remote_ref = normalized.fetch("remote_ref")

          unless remote_ref.is_a?(Hash)
            raise_invalid_import_payload!(
              "Attachment transfer RPC returned a non-object remote_ref.",
              returned_attachment_ids: imports.map { |item| item.is_a?(Hash) ? item["id"] : nil },
            )
          end

          if normalized_imports.key?(id)
            raise_invalid_import_payload!(
              "Attachment transfer RPC returned duplicate import ids.",
              returned_attachment_ids: imports.map { |item| item.is_a?(Hash) ? item["id"] : nil },
            )
          end

          normalized_imports[id] = {
            "id" => id,
            "remote_ref" => AgentCore::Utils.deep_stringify_keys(remote_ref),
          }
        end

        missing_ids = expected_attachment_ids - normalized_imports.keys
        extra_ids = normalized_imports.keys - expected_attachment_ids
        if missing_ids.any? || extra_ids.any?
          raise_invalid_import_payload!(
            "Attachment transfer RPC returned imports that do not match the requested attachment ids.",
            missing_attachment_ids: missing_ids,
            extra_attachment_ids: extra_ids,
            expected_attachment_ids: expected_attachment_ids,
            returned_attachment_ids: normalized_imports.keys,
          )
        end

        expected_attachment_ids.map { |attachment_id| normalized_imports.fetch(attachment_id) }
      rescue KeyError => e
        raise_invalid_import_payload!(
          "Attachment transfer RPC returned an invalid import payload: #{e.message}",
        )
      end

      def raise_invalid_import_payload!(message, **details)
        raise TransferError.new(
          message,
          code: "cybros.conversations.attachment_transfer.rpc_import_payload_invalid",
          failure_class: "remote_api_error",
          details: { agent_id: agent&.id, conversation_id: conversation.id }.merge(details),
        )
      end

      def signed_download_url_for(attachment)
        helpers = Rails.application.routes.url_helpers
        helpers.rails_blob_url(attachment.file, **download_url_options)
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
            host = options[:host].presence || options["host"].presence
            if host.blank?
              AgentCore::ValidationError.raise!(
                "Attachment transfer download URL base is not configured.",
                code: "cybros.conversations.attachment_transfer.download_url_base_missing",
                details: { conversation_id: conversation.id },
              )
            end

            {
              protocol: options[:protocol].presence || options["protocol"].presence || "http",
              host: host,
              port: options[:port].presence || options["port"].presence,
            }.compact
          end
        end
      rescue URI::InvalidURIError
        AgentCore::ValidationError.raise!(
          "Attachment transfer download URL base is invalid.",
          code: "cybros.conversations.attachment_transfer.download_url_base_invalid",
          details: { base_url: base_url, conversation_id: conversation.id },
        )
      end

      def default_port?(uri)
        (uri.scheme == "http" && uri.port == 80) || (uri.scheme == "https" && uri.port == 443)
      end

      def sanitize_filename(filename)
        filename.to_s.gsub(/[^a-zA-Z0-9.\-_]+/, "_")
      end
  end
end
