require "test_helper"
require "digest"

class Conversations::AttachmentManifestBuilderTest < ActiveSupport::TestCase
  test "builds an ordered manifest with normalized metadata and source message binding" do
    conversation = create_conversation!
    user_node = conversation.append_user_message!(content: "Review files").fetch(:user_node)
    note_path = Rails.root.join("test/fixtures/files/attachment-note.txt")
    log_path = Rails.root.join("test/fixtures/files/attachment-log.csv")

    later =
      create_attachment!(
        conversation: conversation,
        source_message_node_id: user_node.id,
        position: 2,
        path: note_path,
        filename: "attachment-note.txt",
        content_type: "text/plain",
      )
    earlier =
      create_attachment!(
        conversation: conversation,
        source_message_node_id: user_node.id,
        position: 1,
        path: log_path,
        filename: "attachment-log.csv",
        content_type: "text/csv",
      )

    manifest = Conversations::AttachmentManifestBuilder.build(
      conversation: conversation,
      source_message_node_id: user_node.id,
    )

    assert_equal [earlier.id, later.id], manifest.map { |entry| entry.fetch("id") }
    assert_equal [1, 2], manifest.map { |entry| entry.fetch("position") }
    assert_equal Array.new(2, user_node.id.to_s), manifest.map { |entry| entry.fetch("source_message_node_id") }
    assert_equal ["attachment-log.csv", "attachment-note.txt"], manifest.map { |entry| entry.fetch("filename") }
    assert_equal ["text/csv", "text/plain"], manifest.map { |entry| entry.fetch("content_type") }
    assert_equal [Digest::SHA256.file(log_path).hexdigest, Digest::SHA256.file(note_path).hexdigest], manifest.map { |entry| entry.fetch("digest") }
    assert_equal [File.size(log_path), File.size(note_path)], manifest.map { |entry| entry.fetch("byte_size") }
  end

  test "merges prepared refs by attachment id without disturbing upload order" do
    conversation = create_conversation!
    user_node = conversation.append_user_message!(content: "Review files").fetch(:user_node)
    first =
      create_attachment!(
        conversation: conversation,
        source_message_node_id: user_node.id,
        position: 1,
        path: Rails.root.join("test/fixtures/files/attachment-note.txt"),
        filename: "attachment-note.txt",
        content_type: "text/plain",
      )
    second =
      create_attachment!(
        conversation: conversation,
        source_message_node_id: user_node.id,
        position: 2,
        path: Rails.root.join("test/fixtures/files/attachment-log.csv"),
        filename: "attachment-log.csv",
        content_type: "text/csv",
      )

    manifest =
      Conversations::AttachmentManifestBuilder.build(
        conversation: conversation,
        source_message_node_id: user_node.id,
        prepared_manifest: [
          { "id" => second.id, "kind" => "attachment_import", "prepared_ref" => { "kind" => "attachment_import", "locator" => "import://second" } },
          { "id" => first.id, "kind" => "attachment_import", "prepared_ref" => { "kind" => "attachment_import", "locator" => "import://first" } },
        ],
      )

    assert_equal [first.id, second.id], manifest.map { |entry| entry.fetch("id") }
    assert_equal ["import://first", "import://second"], manifest.map { |entry| entry.dig("prepared_ref", "locator") }
    assert_equal ["attachment_import", "attachment_import"], manifest.map { |entry| entry.fetch("kind") }
  end

  test "includes prompt image metadata only for representable images when requested" do
    conversation = create_conversation!
    user_node = conversation.append_user_message!(content: "Review files").fetch(:user_node)
    image =
      create_attachment!(
        conversation: conversation,
        source_message_node_id: user_node.id,
        position: 1,
        path: Rails.root.join("test/fixtures/files/attachment-image.png"),
        filename: "attachment-image.png",
        content_type: "image/png",
      )
    note =
      create_attachment!(
        conversation: conversation,
        source_message_node_id: user_node.id,
        position: 2,
        path: Rails.root.join("test/fixtures/files/attachment-note.txt"),
        filename: "attachment-note.txt",
        content_type: "text/plain",
      )

    Current.base_url = "http://example.test"
    manifest =
      Conversations::AttachmentManifestBuilder.build(
        conversation: conversation,
        source_message_node_id: user_node.id,
        prepared_manifest: [
          { "id" => image.id, "kind" => "attachment_import", "prepared_ref" => { "kind" => "attachment_import", "locator" => "import://image" } },
          { "id" => note.id, "kind" => "attachment_import", "prepared_ref" => { "kind" => "attachment_import", "locator" => "import://note" } },
        ],
        include_prompt_images: true,
      )

    assert_match %r{/rails/active_storage/representations/proxy/}, manifest.first.fetch("prompt_image_url")
    assert_equal "image/png", manifest.first.fetch("prompt_image_media_type")
    assert_nil manifest.second["prompt_image_url"]
  ensure
    Current.base_url = nil
  end

  private

    def create_attachment!(conversation:, source_message_node_id:, position:, path:, filename:, content_type:)
      attachment =
        ConversationAttachment.new(
          conversation: conversation,
          source_message_node_id: source_message_node_id,
          position: position,
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
