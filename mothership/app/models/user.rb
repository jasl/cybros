class User < ApplicationRecord
  belongs_to :account, optional: true

  has_many :facilities, class_name: "Conduits::Facility",
           foreign_key: :owner_id, inverse_of: :owner, dependent: :restrict_with_error
end
