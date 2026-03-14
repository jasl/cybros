require "test_helper"
require "yaml"

class OfficialComposeTemplateTest < ActiveSupport::TestCase
  test "official compose sample bootstraps local rails runtime defaults" do
    compose = YAML.safe_load_file(Rails.root.join("compose.yaml.sample"), aliases: true)
    environment = compose.fetch("x-app").fetch("environment")

    assert_equal "production", environment.fetch("RAILS_ENV")
    assert_equal "${SECRET_KEY_BASE:-compose-local-secret-key-base}", environment.fetch("SECRET_KEY_BASE")
    assert_equal "false", environment.fetch("RAILS_ASSUME_SSL")
    assert_equal "false", environment.fetch("RAILS_FORCE_SSL")
    assert_equal "/rails/agent-workspace", environment.fetch("CYBROS_AGENT_WORKSPACE_ROOT")

    %w[
      ACTIVE_RECORD_ENCRYPTION__PRIMARY_KEY
      ACTIVE_RECORD_ENCRYPTION__DETERMINISTIC_KEY
      ACTIVE_RECORD_ENCRYPTION__KEY_DERIVATION_SALT
    ].each do |key|
      assert environment.fetch(key).start_with?("${#{key}:-compose-local-")
    end

    refute compose.fetch("services").key?("agent_deployments")
  end

  test "production docker image seeds the managed agent workspace volume" do
    dockerfile = Rails.root.join("Dockerfile").read

    assert_includes dockerfile, "apt-get install --no-install-recommends -y curl git libjemalloc2 libvips postgresql-client"
    assert_includes dockerfile, "mkdir -p /rails/agent-workspace /rails/storage"
    assert_includes dockerfile, "touch /rails/agent-workspace/.keep"
    assert_includes dockerfile, "chown -R rails:rails /rails/agent-workspace /rails/storage"
  end
end
