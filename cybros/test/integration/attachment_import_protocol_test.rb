require "test_helper"

class AttachmentImportProtocolTest < ActiveSupport::TestCase
  test "protocol accepts descriptor payloads with signed download urls and rejects raw bytes" do
    descriptor = {
      "id" => "attachment-1",
      "filename" => "error.png",
      "content_type" => "image/png",
      "byte_size" => 128,
      "digest" => "sha256:abc123",
      "signed_download_url" => "https://example.test/rails/active_storage/blobs/redirect/signed/error.png",
      "workspace" => {
        "conversation_id" => "conversation:test-default",
        "logical_workspace_id" => "workspace:test-default",
      },
    }

    normalized = Agents::Protocol.normalize_attachment_import_params!("attachments" => [descriptor])

    normalized_descriptor = normalized.fetch("attachments").sole
    assert_equal "conversation:test-default", normalized_descriptor.dig("workspace", "conversation_id")
    refute normalized_descriptor.fetch("workspace").key?("logical_workspace_id")

    error =
      assert_raises(AgentCore::ValidationError) do
        Agents::Protocol.normalize_attachment_import_params!(
          "attachments" => [
            descriptor.merge("bytes_base64" => "aGVsbG8="),
          ],
        )
      end

    assert_equal "cybros.agents.protocol.attachment_descriptor_raw_bytes_are_not_allowed", error.code
  end

  test "fixture server exposes attachments import over rpc" do
    server = Cybros::ProgrammableAgentFixture::Server.new.start

    result =
      server.rpc_call(
        "attachments.import",
        {
          "attachments" => [
            {
              "id" => "attachment-1",
              "filename" => "error.png",
              "content_type" => "image/png",
              "byte_size" => 128,
              "digest" => "sha256:abc123",
              "signed_download_url" => "https://example.test/rails/active_storage/blobs/redirect/signed/error.png",
            },
          ],
        },
      )

    import = result.fetch("imports").first

    assert_equal "attachment-1", import.fetch("id")
    assert_equal "attachment_import", import.dig("remote_ref", "kind")
    assert_equal "error.png", import.dig("remote_ref", "filename")
  ensure
    server&.shutdown
  end
end
