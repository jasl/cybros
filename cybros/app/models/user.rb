class User < ApplicationRecord
  belongs_to :identity

  enum :role, {
    owner: 0,
    admin: 1,
    member: 2,
  }, default: :owner, validate: true
end
