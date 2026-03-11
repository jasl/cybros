require "test_helper"
require "fileutils"

class SystemSettingsAgentProgramsTest < ActionDispatch::IntegrationTest
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

  test "index supports search" do
    sign_in_owner!
    AgentProgram.create!(name: "Alpha", source_kind: "custom", local_path: "storage/agent_programs/alpha")
    AgentProgram.create!(name: "Beta", source_kind: "custom", local_path: "storage/agent_programs/beta")

    get system_settings_agent_programs_path, params: { q: "alp" }
    assert_response :success
    assert_includes response.body, "Alpha"
    assert_not_includes response.body, "Beta"
  end

  test "create validates name and bundled source" do
    sign_in_owner!

    get new_system_settings_agent_program_path
    assert_response :success

    post system_settings_agent_programs_path, params: { agent_program: { name: "", bundled_agent_key: "" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "Name and bundled source are required"
  end

  test "creating the bundled default again keeps the singleton identity instead of renaming it" do
    sign_in_owner!
    bundled = AgentPrograms::BootstrapBundledDefaultService.ensure_program!

    assert_no_difference -> { AgentProgram.count } do
      post system_settings_agent_programs_path, params: {
        agent_program: {
          name: "Renamed bundled default",
          bundled_agent_key: "default",
        },
      }
    end

    assert_redirected_to system_settings_agent_program_path(bundled)
    assert_equal AgentPrograms::BootstrapBundledDefaultService::DEFAULT_PROGRAM_NAME, bundled.reload.name
  end

  test "bundled default show does not advertise manifest error runtime messaging" do
    sign_in_owner!
    bundled = AgentPrograms::BootstrapBundledDefaultService.ensure_program!

    assert_equal "missing", bundled.runtime_surface_status

    get system_settings_agent_program_path(bundled)
    assert_response :success
    refute_includes response.body, "Missing from manifest"
    refute_includes response.body, "Invalid manifest config"
  end

  test "show marks invalid runtime surface config as invalid manifest config" do
    sign_in_owner!

    workspace_root = Dir.mktmpdir("cybros-agent-workspace-")
    runtime_setting = RuntimeSetting.find_or_initialize_by(scope_key: "instance")
    runtime_setting.assign_attributes(
      default_worker_concurrency: 12,
      queue_overrides: {},
      alert_thresholds: {},
      agent_workspace_root: workspace_root,
    )
    runtime_setting.save!

    rel_dir = "test-invalid-runtime-surface"
    abs_dir = Pathname.new(workspace_root).join(rel_dir)
    FileUtils.mkdir_p(abs_dir)
    File.write(abs_dir.join("agent.yml"), <<~YAML)
      name: invalid-runtime-surface
      runtime_surface:
        type: script
        helpers:
          exec: true
    YAML

    program = AgentProgram.create!(name: "Invalid runtime surface", source_kind: "custom", local_path: rel_dir)

    assert_equal(
      {
        "type" => "noop",
        "helpers" => {},
        "stage_limits" => {},
      },
      program.runtime_surface_config,
    )
    assert_equal "invalid", program.runtime_surface_status

    get system_settings_agent_program_path(program)
    assert_response :success
    assert_includes response.body, "Runtime surface"
    assert_includes response.body, "noop"
    assert_includes response.body, "Invalid manifest config"
    refute_includes response.body, "Missing from manifest"
  ensure
    FileUtils.rm_rf(abs_dir)
    FileUtils.rm_rf(workspace_root) if workspace_root.present?
  end

  test "show marks missing runtime surface config as missing from manifest" do
    sign_in_owner!

    workspace_root = Dir.mktmpdir("cybros-agent-workspace-")
    runtime_setting = RuntimeSetting.find_or_initialize_by(scope_key: "instance")
    runtime_setting.assign_attributes(
      default_worker_concurrency: 12,
      queue_overrides: {},
      alert_thresholds: {},
      agent_workspace_root: workspace_root,
    )
    runtime_setting.save!

    rel_dir = "test-missing-runtime-surface"
    abs_dir = Pathname.new(workspace_root).join(rel_dir)
    FileUtils.mkdir_p(abs_dir)
    File.write(abs_dir.join("agent.yml"), <<~YAML)
      name: missing-runtime-surface
    YAML

    program = AgentProgram.create!(name: "Missing runtime surface", source_kind: "custom", local_path: rel_dir)

    assert_equal(
      {
        "type" => "noop",
        "helpers" => {},
        "stage_limits" => {},
      },
      program.runtime_surface_config,
    )
    assert_equal "missing", program.runtime_surface_status

    get system_settings_agent_program_path(program)
    assert_response :success
    assert_includes response.body, "Runtime surface"
    assert_includes response.body, "noop"
    assert_includes response.body, "Missing from manifest"
    refute_includes response.body, "Invalid manifest config"
  ensure
    FileUtils.rm_rf(abs_dir)
    FileUtils.rm_rf(workspace_root) if workspace_root.present?
  end

  test "copy as custom agent creates a forked program and git repo" do
    sign_in_owner!
    root = Dir.mktmpdir("cybros-agent-workspace-")
    runtime_setting = RuntimeSetting.find_or_initialize_by(scope_key: "instance")
    runtime_setting.assign_attributes(
      default_worker_concurrency: 12,
      queue_overrides: {},
      alert_thresholds: {},
      agent_workspace_root: root,
    )
    runtime_setting.save!
    bundled = AgentPrograms::BootstrapBundledDefaultService.ensure_program!

    assert_difference -> { AgentProgram.count }, +1 do
      post fork_system_settings_agent_program_path(bundled), params: { name: "My assistant" }
    end

    forked = AgentProgram.find_by!(name: "My assistant")

    assert_redirected_to system_settings_agent_program_path(forked)
    assert_equal "custom", forked.source_kind
    assert_equal bundled.id, forked.forked_from_agent_program_id
    assert_equal true, forked.absolute_local_path.join(".git").directory?
    refute_equal "default", forked.manifest_snapshot.fetch("agent_program_key")
  ensure
    FileUtils.rm_rf(root) if root.present?
  end

  test "copy as custom agent rejects a missing workspace root" do
    sign_in_owner!
    bundled = AgentPrograms::BootstrapBundledDefaultService.ensure_program!

    RuntimeSetting.delete_all

    with_default_agent_workspace_root("") do
      assert_no_difference -> { AgentProgram.count } do
        post fork_system_settings_agent_program_path(bundled), params: { name: "My assistant" }
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Agent workspace root must be configured before creating custom agents"
  end

  test "copy as custom agent rejects the app repository workspace root" do
    sign_in_owner!
    bundled = AgentPrograms::BootstrapBundledDefaultService.ensure_program!
    RuntimeSetting.find_or_initialize_by(scope_key: "instance").tap do |setting|
      setting.assign_attributes(
        default_worker_concurrency: 12,
        queue_overrides: {},
        alert_thresholds: {},
        agent_workspace_root: Rails.root.to_s,
      )
      setting.save!(validate: false)
    end

    assert_no_difference -> { AgentProgram.count } do
      post fork_system_settings_agent_program_path(bundled), params: { name: "My assistant" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Agent workspace root must point outside the Cybros app repository"
  end
end
