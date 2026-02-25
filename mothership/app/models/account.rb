class Account < ApplicationRecord
  has_many :users, dependent: :nullify

  has_many :territories, class_name: "Conduits::Territory", dependent: :restrict_with_error
  has_many :facilities,  class_name: "Conduits::Facility",  dependent: :restrict_with_error
  has_many :directives,  class_name: "Conduits::Directive",  dependent: :restrict_with_error
  has_many :policies,    class_name: "Conduits::Policy",     dependent: :restrict_with_error

  validates :name, presence: true
end
