# frozen_string_literal: true

class AgentProgram < ApplicationRecord
  validates :name, presence: true

  def bundled_profile?
    profile_source.to_s.strip != ""
  end
end

