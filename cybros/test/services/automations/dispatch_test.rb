require "test_helper"

class Automations::DispatchTest < ActiveSupport::TestCase
  test "dispatch creates one queued automation run with durable schedule facts" do
    automation = create_automation!
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    dispatch_key = "#{automation.id}:#{scheduled_for.iso8601}"

    run =
      Automations::Dispatch.call!(
        automation: automation,
        scheduled_for: scheduled_for,
        dispatch_key: dispatch_key,
        trigger_snapshot: { "kind" => "schedule", "scheduled_for" => scheduled_for.iso8601 },
      )

    assert_equal "queued", run.status
    assert_equal dispatch_key, run.dispatch_key
    assert_equal scheduled_for, run.scheduled_for
    assert_equal automation.id, run.snapshot.dig("automation", "id")
    assert_equal automation.agent_program_id, run.snapshot.dig("automation", "agent_program_id")
    assert_equal automation.execution_target_id, run.snapshot.dig("automation", "execution_target_id")
    assert_equal "full_access", run.snapshot.dig("automation", "permission_mode")
    assert_equal "rrule", run.snapshot.dig("schedule", "kind")
    assert_equal automation.schedule_rrule, run.snapshot.dig("schedule", "rrule")
    assert_equal automation.schedule_timezone, run.snapshot.dig("schedule", "timezone")
    assert_equal scheduled_for.iso8601, run.snapshot.dig("schedule", "scheduled_for")
    assert_equal "schedule", run.snapshot.dig("trigger", "kind")
  end

  test "dispatch is idempotent for the same logical trigger delivery" do
    automation = create_automation!
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    dispatch_key = "#{automation.id}:#{scheduled_for.iso8601}"

    first =
      Automations::Dispatch.call!(
        automation: automation,
        scheduled_for: scheduled_for,
        dispatch_key: dispatch_key,
        trigger_snapshot: { "kind" => "schedule", "scheduled_for" => scheduled_for.iso8601 },
      )

    assert_no_difference -> { AutomationRun.count } do
      second =
        Automations::Dispatch.call!(
          automation: automation,
          scheduled_for: scheduled_for,
          dispatch_key: dispatch_key,
          trigger_snapshot: { "kind" => "schedule", "scheduled_for" => scheduled_for.iso8601 },
        )

      assert_equal first.id, second.id
    end
  end

  private

    def create_automation!(status: "active", hour: 9, minute: 0, timezone: "UTC")
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
        status: status,
        schedule_kind: "rrule",
        schedule_rrule: "FREQ=DAILY;BYHOUR=#{hour};BYMINUTE=#{minute}",
        schedule_timezone: timezone,
        task_payload: { "kind" => "scheduled_prompt", "prompt" => "Ship it" },
      )
    end
end
