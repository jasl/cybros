require "test_helper"
require "digest"

class ConversationAttachmentTest < ActiveSupport::TestCase
  test "persists an active-storage-backed file with a message-scoped digest snapshot" do
    conversation = create_conversation!
    user_node = conversation.append_user_message!(content: "See file").fetch(:user_node)
    path = Rails.root.join("test/fixtures/files/attachment-note.txt")

    attachment =
      ConversationAttachment.new(
        conversation: conversation,
        source_message_node_id: user_node.id,
        position: 1,
      )
    attachment.file.attach(
      io: File.open(path, "rb"),
      filename: "attachment-note.txt",
      content_type: "text/plain",
    )
    attachment.save!
    attachment.reload

    assert_predicate attachment.file, :attached?
    assert_equal Digest::SHA256.file(path).hexdigest, attachment.sha256_digest
    assert_equal user_node.id.to_s, attachment.source_message_node_id
    assert_equal "attachment-note.txt", attachment.file.filename.to_s
    assert_equal "text/plain", attachment.file.content_type
  end
end
