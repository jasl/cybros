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

provider_name = ENV["LLM_PROVIDER_NAME"].to_s.strip
provider_base_url = ENV["LLM_PROVIDER_BASE_URL"].to_s.strip
provider_api_key = ENV["OPENROUTER_API_KEY"].to_s.strip

if provider_name.present? && provider_base_url.present?
  record =
    LLMProvider.find_or_initialize_by(name: provider_name, base_url: provider_base_url)

  record.api_format ||= "openai"
  record.priority ||= 0

  record.api_key = provider_api_key if provider_api_key.present?

  record.save! if record.changed?
end

unless AgentProgram.exists?
  default_profile = "default-assistant"
  if AgentPrograms::BundledProfiles.profile_path(default_profile)
    AgentPrograms::Creator.create_from_profile!(name: "Default assistant", profile_source: default_profile)
  end
end
