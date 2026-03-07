# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

Account.instance

openai_api_key = ENV["OPENAI_API_KEY"].to_s.strip
openrouter_api_key = ENV["OPENROUTER_API_KEY"].to_s.strip

if openai_api_key.present?
  record = LLMProvider.find_or_initialize_by(provider_key: "openai")
  record.credential_type = "api_key"
  record.api_key = openai_api_key
  record.save! if record.changed?
end

if openrouter_api_key.present?
  record = LLMProvider.find_or_initialize_by(provider_key: "openrouter")
  record.credential_type = "api_key"
  record.api_key = openrouter_api_key
  record.save! if record.changed?
end

unless AgentProgram.exists?
  default_profile = "default-assistant"
  if AgentPrograms::BundledProfiles.profile_path(default_profile)
    AgentPrograms::Creator.create_from_profile!(name: "Default assistant", profile_source: default_profile)
  end
end
