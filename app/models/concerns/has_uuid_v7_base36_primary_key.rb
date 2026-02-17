module HasUuidV7Base36PrimaryKey
  extend ActiveSupport::Concern

  included do
    before_create :assign_uuid_v7_base36_primary_key
  end

  private
    def assign_uuid_v7_base36_primary_key
      self.id ||= UuidV7::Base36.generate
    end
end
