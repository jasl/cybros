class LanePromptBufferEntry < ApplicationRecord
  belongs_to :lane, class_name: "DAG::Lane"

  scope :ordered, -> { order(:seq, :id) }

  before_validation :normalize_buffer_name
  before_validation :normalize_content
  before_validation :normalize_kind
  before_validation :normalize_metadata

  validates :buffer_name, presence: true
  validates :kind, presence: true
  validates :content, presence: true
  validates :seq, numericality: { only_integer: true, greater_than: 0 }
  validates :estimated_tokens, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :priority, numericality: { only_integer: true }
  validates :seq, uniqueness: { scope: %i[lane_id buffer_name] }

  private

    def normalize_buffer_name
      self.buffer_name = buffer_name.to_s.strip.presence
    end

    def normalize_content
      self.content = content.to_s.strip.presence
    end

    def normalize_kind
      self.kind = kind.to_s.strip.presence || "note"
    end

    def normalize_metadata
      self.metadata = normalize_json(metadata || {})
    end

    def normalize_json(payload)
      case payload
      when Hash
        payload.each_with_object({}) do |(nested_key, nested_value), normalized|
          normalized[nested_key.to_s] = normalize_json(nested_value)
        end
      when Array
        payload.map { |element| normalize_json(element) }
      else
        payload
      end
    end
end
