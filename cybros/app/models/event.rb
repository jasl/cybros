class Event < ApplicationRecord
  belongs_to :conversation
  belongs_to :subject, polymorphic: true

  validates :event_type, presence: true
end
