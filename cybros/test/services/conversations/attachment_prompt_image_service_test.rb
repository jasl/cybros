require "test_helper"

class Conversations::AttachmentPromptImageServiceTest < ActiveSupport::TestCase
  test "returns a representation proxy url for valid image attachments" do
    attachment = create_attachment!(path: Rails.root.join("test/fixtures/files/attachment-image.png"), filename: "attachment-image.png", content_type: "image/png")

    Current.base_url = "http://example.test"
    result = Conversations::AttachmentPromptImageService.build(attachment: attachment)

    assert_match %r{/rails/active_storage/representations/proxy/}, result.fetch("prompt_image_url")
    assert_equal "image/png", result.fetch("media_type")
    assert_nil result["prompt_image_error"]
  ensure
    Current.base_url = nil
  end

  test "returns nil for non-image attachments" do
    attachment = create_attachment!(path: Rails.root.join("test/fixtures/files/attachment-note.txt"), filename: "attachment-note.txt", content_type: "text/plain")

    Current.base_url = "http://example.test"
    result = Conversations::AttachmentPromptImageService.build(attachment: attachment)

    assert_nil result["prompt_image_url"]
    assert_nil result["prompt_image_error"]
  ensure
    Current.base_url = nil
  end

  test "gracefully degrades for invalid image bytes" do
    attachment = create_attachment!(path: Rails.root.join("test/fixtures/files/attachment-note.txt"), filename: "broken-image.png", content_type: "image/png")

    Current.base_url = "http://example.test"
    result = Conversations::AttachmentPromptImageService.build(attachment: attachment)

    assert_nil result["prompt_image_url"]
    assert_includes result.fetch("prompt_image_error"), "could not be forwarded"
  ensure
    Current.base_url = nil
  end

  private

    def create_attachment!(path:, filename:, content_type:)
      conversation = create_conversation!
      user_node = conversation.append_user_message!(content: "Inspect").fetch(:user_node)
      attachment =
        ConversationAttachment.new(
        conversation: conversation,
        source_message_node_id: user_node.id,
        position: 1,
      )
      attachment.file.attach(
        io: File.open(path, "rb"),
        filename: filename,
        content_type: content_type,
      )
      attachment.save!
      attachment
    end
end
