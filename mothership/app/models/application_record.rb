class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # SQLite has no built-in UUID generator — assign UUIDv7 before insert.
  before_create { self.id = SecureRandom.uuid_v7 if id.blank? }
end
