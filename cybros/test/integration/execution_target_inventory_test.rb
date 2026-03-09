require "test_helper"

class ExecutionTargetInventoryTest < ActionDispatch::IntegrationTest
  test "execution_target list and get return visible inventory with switch previews" do
    current_target = create_execution_target!(name: "Current target")
    alternate_target = create_execution_target!(name: "Alternate target")
    _inactive_target = create_execution_target!(name: "Inactive target", target_status: "inactive")
    conversation = create_conversation!(default_execution_target: current_target, permission_mode: "default")

    payload = AgentRpc::KernelServices::ExecutionTargets.list(entrypoint: conversation)

    assert_equal [alternate_target.id, current_target.id].sort, payload.fetch("targets").map { |target| target.fetch("id") }.sort

    current_summary = payload.fetch("targets").find { |target| target.fetch("id") == current_target.id }
    assert_equal true, current_summary.fetch("is_default")
    assert_equal "allow", current_summary.dig("switch_decision_preview", "decision")
    assert_equal "available", current_summary.fetch("availability")
    assert_equal "healthy", current_summary.fetch("health_status")

    alternate_summary = AgentRpc::KernelServices::ExecutionTargets.get(entrypoint: conversation, execution_target_id: alternate_target.id).fetch("target")
    assert_equal alternate_target.id, alternate_summary.fetch("id")
    assert_equal "Alternate target", alternate_summary.fetch("name")
    assert_equal "Alternate target workspace", alternate_summary.fetch("workspace_label")
    assert_equal "Alternate target host", alternate_summary.fetch("location_label")
    assert_equal "confirm", alternate_summary.dig("switch_decision_preview", "decision")
  end

  test "operator target management surface lists registered execution targets" do
    sign_in_owner!
    active_target = create_execution_target!(name: "Active target")
    inactive_target = create_execution_target!(name: "Inactive target", target_status: "inactive")

    get system_settings_execution_targets_path

    assert_response :success
    assert_includes response.body, "Execution Targets"
    assert_includes response.body, active_target.name
    assert_includes response.body, inactive_target.name
  end

  private

    def sign_in_owner!
      identity =
        Identity.create!(
          email: "admin@example.com",
          password: "Passw0rd",
          password_confirmation: "Passw0rd",
        )

      User.create!(identity: identity, role: :owner)

      post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?
    end

    def create_conversation!(default_execution_target:, permission_mode:)
      user = User.first || User.create!(identity: Identity.create!(email: "owner@example.com", password: "Passw0rd", password_confirmation: "Passw0rd"), role: :owner)

      Conversation.create!(
        user: user,
        title: "Chat",
        default_execution_target: default_execution_target,
        permission_mode: permission_mode,
        metadata: {},
      )
    end

    def create_execution_target!(name:, target_status: "active", workspace_status: "active", location_status: "active")
      location =
        ExecutionLocation.create!(
          name: "#{name} host",
          kind: "host",
          platform: "macos_arm64",
          status: location_status,
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      workspace =
        Workspace.create!(
          execution_location: location,
          name: "#{name} workspace",
          root_path: "/tmp/#{name.parameterize}-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: workspace_status,
          capability_tags: ["git", "shell"],
          tags: ["fixture"],
        )

      ExecutionTarget.create!(
        execution_location: location,
        workspace: workspace,
        name: name,
        status: target_status,
        sandboxed: true,
      )
    end
end
