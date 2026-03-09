class ConversationKVEntry < ApplicationRecord
  belongs_to :conversation
  belongs_to :written_by, polymorphic: true, optional: true

  before_validation :normalize_key
  before_validation :normalize_value

  validates :key, presence: true, uniqueness: { scope: :conversation_id }

  validate :value_must_not_be_nil
  validate :writer_attribution_must_be_complete

  private

    def normalize_key
      self.key = key.to_s.strip.presence
    end

    def normalize_value
      self.value = normalize_json(value)
    end

    def value_must_not_be_nil
      errors.add(:value, "must not be nil") if self[:value].nil?
    end

    def writer_attribution_must_be_complete
      type_present = written_by_type.present?
      id_present = written_by_id.present?
      return if type_present == id_present

      errors.add(:written_by, "must include both type and id")
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
