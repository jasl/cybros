class Account < ApplicationRecord
  def self.instance
    first_or_create!
  end
end
