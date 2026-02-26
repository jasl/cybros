class Identity < ApplicationRecord
  has_secure_password

  has_one :user, dependent: :destroy
  has_many :sessions, dependent: :destroy

  normalizes :email, with: ->(email) { email.to_s.downcase.strip }

  validates :email, presence: true
  validates :email, uniqueness: { case_sensitive: false }
  validate :email_must_be_valid

  private

    def email_must_be_valid
      address = email.to_s.strip
      return errors.add(:email, :blank) if address.blank?

      # Purposefully simple: avoid coupling Phase 0 to specific validators.
      errors.add(:email, :invalid) unless address.include?("@") && address.include?(".")
    end
end
