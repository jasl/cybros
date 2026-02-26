class User < ApplicationRecord
  belongs_to :identity

  enum :role, {
    owner: "owner",
    admin: "admin",
    member: "member",
    system: "system",
  }, default: :owner, validate: true
end
