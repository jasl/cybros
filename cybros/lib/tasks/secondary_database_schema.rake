namespace :cybros do
  desc "Ensure configured secondary database schemas exist for the current Rails environment"
  task ensure_secondary_database_schemas: :environment do
    Cybros::SecondaryDatabaseSchema.ensure_configured_schemas!
  end
end
