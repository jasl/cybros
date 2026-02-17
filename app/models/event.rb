class Event < ApplicationRecord
  include HasUuidV7Base36PrimaryKey

  belongs_to :conversation
  belongs_to :subject, polymorphic: true, optional: true

  validates :event_type, presence: true
end
