require "test_helper"
require "yaml"

class OfficialComposeTemplateTest < ActiveSupport::TestCase
  test "official compose sample bootstraps local rails runtime defaults" do
    compose = YAML.safe_load_file(Rails.root.join("compose.yaml.sample"), aliases: true)
    environment = compose.fetch("x-app").fetch("environment")
    app_volumes = Array(compose.fetch("x-app").fetch("volumes"))
    services = compose.fetch("services")

    assert_equal "production", environment.fetch("RAILS_ENV")
    assert_equal "${SECRET_KEY_BASE:-compose-local-secret-key-base}", environment.fetch("SECRET_KEY_BASE")
    assert_equal "false", environment.fetch("RAILS_ASSUME_SSL")
    assert_equal "false", environment.fetch("RAILS_FORCE_SSL")
    assert_equal "/rails/agent-workspace", environment.fetch("CYBROS_AGENT_WORKSPACE_ROOT")
    assert_equal "http://app", environment.fetch("CYBROS_AGENT_RPC_CALLBACK_BASE_URL")
    assert_equal "http://claw/rpc", environment.fetch("CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL")
    assert_equal "${CYBROS_BUNDLED_CLAW_BEARER:-secret://bundled-claw:compose}", environment.fetch("CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER")
    assert_equal "${CYBROS_BUNDLED_CLAW_FINGERPRINT:-deployment:bundled-claw:compose}", environment.fetch("CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT")
    assert_includes app_volumes, "../agents:/agents:ro"

    %w[
      ACTIVE_RECORD_ENCRYPTION__PRIMARY_KEY
      ACTIVE_RECORD_ENCRYPTION__DETERMINISTIC_KEY
      ACTIVE_RECORD_ENCRYPTION__KEY_DERIVATION_SALT
    ].each do |key|
      assert environment.fetch(key).start_with?("${#{key}:-compose-local-")
    end

    assert services.key?("claw")
    refute services.key?("agent_deployments")

    claw = services.fetch("claw")
    claw_build = claw.fetch("build")
    claw_environment = claw.fetch("environment")
    claw_volumes = Array(claw.fetch("volumes"))

    assert_equal "../agents/claw", claw_build.fetch("context")
    assert_equal "${CYBROS_BUNDLED_CLAW_BEARER:-secret://bundled-claw:compose}", claw_environment.fetch("CLAW_REQUIRED_BEARER")
    assert_equal "${CYBROS_BUNDLED_CLAW_FINGERPRINT:-deployment:bundled-claw:compose}", claw_environment.fetch("CLAW_DEPLOYMENT_FINGERPRINT")
    assert_equal "/rails/agent-workspace/bundled/claw", claw_environment.fetch("CLAW_WORKSPACE_ROOT")
    assert_includes claw_volumes, "agent-workspace:/rails/agent-workspace"
    assert_includes claw_volumes, "claw-storage:/rails/storage"
  end

  test "production docker image seeds the managed agent workspace volume" do
    dockerfile = Rails.root.join("Dockerfile").read

    assert_includes dockerfile, "apt-get install --no-install-recommends -y curl git libjemalloc2 libvips postgresql-client"
    assert_includes dockerfile, "mkdir -p /rails/agent-workspace /rails/storage"
    assert_includes dockerfile, "touch /rails/agent-workspace/.keep"
    assert_includes dockerfile, "chown -R rails:rails /rails/agent-workspace /rails/storage"
  end
end
