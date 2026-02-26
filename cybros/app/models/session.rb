# frozen_string_literal: true

class Session < ApplicationRecord
  belongs_to :identity

  def self.start!(identity:, ip_address:, user_agent:)
    create!(
      identity: identity,
      ip_address: ip_address,
      user_agent: user_agent,
      last_seen_at: Time.current,
    )
  end
end

