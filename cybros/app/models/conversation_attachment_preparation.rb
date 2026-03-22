class ConversationAttachmentPreparation < ApplicationRecord
  belongs_to :conversation_attachment
  belongs_to :run_draft
  belongs_to :recognized_deployment

  validates :transfer_mode, presence: true
  validates :status, presence: true
  validates :prepared_ref, presence: true
  validates :prepared_at, presence: true
  validates :conversation_attachment_id, uniqueness: { scope: :run_draft_id }

  def prepared_ref
    value = self[:prepared_ref]
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end

  def prepared?
    status.to_s == "prepared"
  end
end
