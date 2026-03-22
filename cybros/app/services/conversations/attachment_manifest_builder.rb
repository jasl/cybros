module Conversations
  class AttachmentManifestBuilder
    class << self
      def build(conversation:, source_message_node_id:, prepared_manifest: nil, include_prompt_images: false, url_options: nil)
        new(
          conversation: conversation,
          source_message_node_id: source_message_node_id,
          prepared_manifest: prepared_manifest,
          include_prompt_images: include_prompt_images,
          url_options: url_options,
        ).build
      end
    end

    def initialize(conversation:, source_message_node_id:, prepared_manifest: nil, include_prompt_images: false, url_options: nil)
      @conversation = conversation
      @source_message_node_id = source_message_node_id.to_s
      @prepared_manifest = Array(prepared_manifest).index_by { |entry| entry.fetch("id").to_s }
      @include_prompt_images = include_prompt_images == true
      @url_options = url_options
    end

    def build
      attachments.map do |attachment|
        entry = {
          "id" => attachment.id,
          "position" => attachment.position,
          "source_message_node_id" => attachment.source_message_node_id.to_s,
          "filename" => attachment.filename,
          "content_type" => attachment.content_type,
          "byte_size" => attachment.byte_size,
          "digest" => attachment.digest,
        }

        prepared_entry = prepared_manifest[attachment.id.to_s]
        if prepared_entry.present?
          entry["kind"] = prepared_entry["kind"].to_s.presence || prepared_entry.dig("prepared_ref", "kind").to_s.presence
          entry["prepared_ref"] = prepared_entry["prepared_ref"]
        end

        prompt_image = prompt_image_payload_for(attachment)
        if prompt_image.present?
          entry["prompt_image_url"] = prompt_image["prompt_image_url"] if prompt_image["prompt_image_url"].present?
          entry["prompt_image_media_type"] = prompt_image["media_type"] if prompt_image["media_type"].present?
          entry["prompt_image_error"] = prompt_image["prompt_image_error"] if prompt_image["prompt_image_error"].present?
        end

        entry.compact
      end
    end

    private

      attr_reader :conversation, :source_message_node_id, :prepared_manifest, :url_options

      def attachments
        conversation
          .conversation_attachments
          .where(source_message_node_id: source_message_node_id)
          .includes(file_attachment: :blob)
          .order(:position, :id)
      end

      def prompt_image_payload_for(attachment)
        return nil unless @include_prompt_images
        return nil unless attachment.image?

        Conversations::AttachmentPromptImageService.build(
          attachment: attachment,
          url_options: url_options,
        )
      end
  end
end
