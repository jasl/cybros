require "test_helper"

class AutomationRunTest < ActiveSupport::TestCase
  test "stores immutable automation snapshot fields" do
    run = build_run

    assert_predicate run, :valid?
    run.save!

    assert_equal "queued", run.status
    assert_equal({ "automation" => { "permission_mode" => "full_access" } }, run.snapshot)
  end

  test "requires automation status scheduling facts and snapshot" do
    run = AutomationRun.new

    refute_predicate run, :valid?
    assert_includes run.errors[:automation], "must exist"
    assert_includes run.errors[:status], "can't be blank"
    assert_includes run.errors[:scheduled_for], "can't be blank"
    assert_includes run.errors[:snapshot], "must be a JSON object"
  end

  test "keeps immutable snapshot fields readonly after creation" do
    run = build_run
    run.save!

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      run.update!(
        scheduled_for: 1.hour.from_now.change(usec: 0),
        snapshot: { "automation" => { "permission_mode" => "default" } },
      )
    end

    run.reload
    assert_equal({ "automation" => { "permission_mode" => "full_access" } }, run.snapshot)
  end

  private

    def build_run
      AutomationRun.new(
        automation: create_automation!,
        initiated_by_user: create_user!,
        status: "queued",
        approval_state: {},
        scheduled_for: Time.current.change(usec: 0),
        snapshot: { "automation" => { "permission_mode" => "full_access" } },
      )
    end

    def create_automation!
      program =
        AgentProgram.create!(
          name: "Automation Program #{SecureRandom.hex(4)}",
          config_namespace: "automation.program.#{SecureRandom.hex(4)}",
          published_contract_fingerprint: "contract:v1",
          manifest_snapshot: { "name" => "Automation Program" },
          global_config: {},
          global_config_schema: { "type" => "object" },
          conversation_config_schema: { "type" => "object" },
          config_schema_fingerprint: "config:v1",
        )
      location =
        ExecutionLocation.create!(
          name: "Automation host #{SecureRandom.hex(4)}",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["automation"],
          max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      workspace =
        Workspace.create!(
          execution_location: location,
          name: "Automation workspace #{SecureRandom.hex(4)}",
          root_path: "/tmp/automation-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["automation"],
        )
      target =
        ExecutionTarget.create!(
          execution_location: location,
          workspace: workspace,
          name: "Automation target #{SecureRandom.hex(4)}",
          status: "active",
          sandboxed: true,
        )

      Automation.create!(
        user: create_user!,
        agent_program: program,
        execution_target: target,
        permission_mode: "full_access",
        status: "active",
        schedule_kind: "rrule",
        schedule_rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
        schedule_timezone: "UTC",
        task_payload: { "kind" => "scheduled_prompt", "prompt" => "Ship it" },
      )
    end
end
