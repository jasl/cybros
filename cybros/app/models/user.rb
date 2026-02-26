class User < ApplicationRecord
  belongs_to :identity
  has_many :conversations, dependent: :destroy

  enum :role, {
    owner: "owner",
    admin: "admin",
    member: "member",
    system: "system",
  }, default: :owner, validate: true
end
