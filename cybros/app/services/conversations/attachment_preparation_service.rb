require "json"

module Conversations
  class AttachmentPreparationService
    PREPARED_STATUS = "prepared".freeze

    def self.ensure_prepared!(conversation:, source_message_node_id:, run_draft:)
      new(
        conversation: conversation,
        source_message_node_id: source_message_node_id,
        run_draft: run_draft,
      ).ensure_prepared!
    end

    def self.ensure_prepared_for_run!(conversation:, source_message_node_id:, conversation_run:)
      run_draft_id = conversation_run.snapshot.dig("draft", "id").to_s.presence
      AgentCore::ValidationError.raise!(
        "Conversation run is missing its originating run draft for attachment preparation.",
        code: "cybros.conversations.attachment_preparation.run_draft_missing",
        details: { conversation_run_id: conversation_run.id, conversation_id: conversation.id },
      ) if run_draft_id.blank?

      run_draft = conversation.run_drafts.find_by(id: run_draft_id)
      AgentCore::ValidationError.raise!(
        "Conversation run references an unknown run draft for attachment preparation.",
        code: "cybros.conversations.attachment_preparation.run_draft_not_found",
        details: { conversation_run_id: conversation_run.id, conversation_id: conversation.id, run_draft_id: run_draft_id },
      ) if run_draft.nil?

      ensure_prepared!(
        conversation: conversation,
        source_message_node_id: source_message_node_id,
        run_draft: run_draft,
      )
    end

    def initialize(conversation:, source_message_node_id:, run_draft:)
      @conversation = conversation
      @source_message_node_id = source_message_node_id.to_s
      @run_draft = run_draft
    end

    def ensure_prepared!
      return [] if attachments.empty?

      existing_preparations = load_existing_preparations
      attachments_to_prepare = attachments.select { |attachment| prepare_attachment?(attachment, existing_preparations[attachment.id.to_s]) }

      if attachments_to_prepare.any?
        transfer = Conversations::AttachmentTransferService.transfer!(
          conversation: conversation,
          attachment_ids: attachments_to_prepare.map(&:id),
          agent: run_draft.agent,
          recognized_deployment: run_draft.recognized_deployment,
        )
        persist_preparations!(attachments_to_prepare, transfer: transfer)
      end

      ordered_preparations = load_existing_preparations
      manifest =
        attachments.map do |attachment|
          preparation = ordered_preparations.fetch(attachment.id.to_s)
          {
            "id" => attachment.id,
            "position" => attachment.position,
            "source_message_node_id" => attachment.source_message_node_id.to_s,
            "filename" => attachment.filename,
            "content_type" => attachment.content_type,
            "byte_size" => attachment.byte_size,
            "digest" => attachment.digest,
            "prepared_ref" => preparation.prepared_ref,
          }
        end

      write_turn_manifest!(manifest) if local_workspace_preparations?(manifest)
      manifest
    end

    private

      attr_reader :conversation, :source_message_node_id, :run_draft

      def attachments
        @attachments ||=
          conversation.conversation_attachments
            .where(source_message_node_id: source_message_node_id)
            .includes(file_attachment: :blob)
            .order(:position, :id)
            .to_a
      end

      def load_existing_preparations
        ConversationAttachmentPreparation
          .where(conversation_attachment_id: attachments.map(&:id), run_draft_id: run_draft.id)
          .index_by { |preparation| preparation.conversation_attachment_id.to_s }
      end

      def prepare_attachment?(attachment, preparation)
        return true if preparation.nil?
        return true unless preparation.prepared?
        return true if preparation.prepared_ref.blank?

        return workspace_ref_missing?(preparation.prepared_ref) if preparation.prepared_ref["kind"].to_s == "workspace_file"

        false
      end

      def workspace_ref_missing?(prepared_ref)
        absolute_path = prepared_ref["absolute_path"].to_s.presence
        return true if absolute_path.blank?

        !File.exist?(absolute_path)
      end

      def persist_preparations!(attachments_to_prepare, transfer:)
        imports_by_id = Array(transfer.fetch("imports")).index_by { |entry| entry.fetch("id").to_s }
        transfer_mode = transfer.fetch("transfer_mode")

        attachments_to_prepare.each do |attachment|
          preparation =
            ConversationAttachmentPreparation.find_or_initialize_by(
              conversation_attachment: attachment,
              run_draft: run_draft,
            )
          preparation.recognized_deployment = run_draft.recognized_deployment
          preparation.transfer_mode = transfer_mode
          preparation.status = PREPARED_STATUS
          preparation.prepared_ref = imports_by_id.fetch(attachment.id.to_s).fetch("remote_ref")
          preparation.prepared_at = Time.current
          preparation.save!
        end
      end

      def local_workspace_preparations?(manifest)
        manifest.any? && manifest.all? { |entry| entry.dig("prepared_ref", "kind").to_s == "workspace_file" }
      end

      def write_turn_manifest!(manifest)
        workspace_root = Conversations::WorkspaceInitializer.materialize_conversation_directory!(conversation: conversation)
        directory = workspace_root.join("attachments", source_message_node_id)
        directory.mkpath
        File.write(directory.join("manifest.json"), JSON.pretty_generate(manifest))
      end
  end
end
