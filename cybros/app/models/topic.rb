class Topic < ApplicationRecord
  MAIN = "main"
  BRANCH = "branch"

  ROLES = [MAIN, BRANCH].freeze

  enum :role, ROLES.index_by(&:itself)

  belongs_to :conversation
  has_one :dag_lane, as: :attachable, class_name: "DAG::Lane", dependent: :nullify

  validates :role, inclusion: { in: ROLES }
end
