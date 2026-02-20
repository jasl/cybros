class AgentMemoryEntry < ApplicationRecord
  belongs_to :conversation, optional: true

  validates :content, presence: true

  has_neighbors :embedding
end
