module Conduits
  class EnrollmentToken < ApplicationRecord
    self.table_name = "conduits_enrollment_tokens"

    TOKEN_TTL = 1.hour

    belongs_to :account
    belongs_to :created_by_user, class_name: "User"

    validates :token_digest, presence: true, uniqueness: true
    validates :expires_at, presence: true

    scope :usable, -> { where(used_at: nil, revoked_at: nil).where("expires_at > ?", Time.current) }

    # Generate a new enrollment token, returning the plaintext token (shown once)
    def self.generate!(account:, user:, labels: {}, ttl: TOKEN_TTL)
      plaintext_token = SecureRandom.urlsafe_base64(32)

      record = create!(
        account: account,
        created_by_user: user,
        token_digest: Digest::SHA256.hexdigest(plaintext_token),
        labels: labels,
        expires_at: Time.current + ttl
      )

      [record, plaintext_token]
    end

    # Find and validate a token by plaintext value
    def self.find_usable(plaintext_token)
      digest = Digest::SHA256.hexdigest(plaintext_token)
      usable.find_by(token_digest: digest)
    end

    def use!
      raise "Token already used" if used_at.present?
      raise "Token revoked" if revoked_at.present?
      raise "Token expired" if expired?

      # Atomic CAS: only mark as used if still unused, preventing TOCTOU races.
      rows = self.class.where(id: id, used_at: nil).update_all(used_at: Time.current)
      raise "Token already used (concurrent race)" if rows == 0

      reload
    end

    def revoke!
      update!(revoked_at: Time.current)
    end

    def expired?
      expires_at < Time.current
    end

    def usable?
      used_at.nil? && revoked_at.nil? && !expired?
    end
  end
end
