require "digest"

class ConversationAttachment < ApplicationRecord
  belongs_to :conversation

  has_one_attached :file

  after_commit :backfill_sha256_digest!, on: %i[create update]

  validates :source_message_node_id, presence: true
  validates :position, presence: true, numericality: { only_integer: true, greater_than: 0 }

  validate :file_must_be_attached

  def filename
    file.filename.to_s
  end

  def content_type
    file.content_type.to_s
  end

  def byte_size
    file.byte_size
  end

  def image?
    content_type.start_with?("image/")
  end

  def digest
    sha256_digest.presence || compute_sha256_digest
  end

  def compute_sha256_digest
    return nil unless file.attached?

    Digest::SHA256.hexdigest(file.download)
  end

  private

    def backfill_sha256_digest!
      digest = compute_sha256_digest
      return if digest.blank?
      return if sha256_digest.to_s == digest

      update_columns(sha256_digest: digest, updated_at: Time.current)
    end

    def file_must_be_attached
      errors.add(:file, "must be attached") unless file.attached?
    end
end
