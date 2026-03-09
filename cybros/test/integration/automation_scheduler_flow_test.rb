require "test_helper"

class AutomationSchedulerFlowTest < ActiveSupport::TestCase
  test "scheduler dispatches due active automations once per schedule window" do
    due = create_automation!(status: "active", hour: 9, minute: 0)
    paused = create_automation!(status: "paused", hour: 9, minute: 0)
    later = create_automation!(status: "active", hour: 10, minute: 0)
    now = Time.utc(2026, 3, 9, 9, 0, 0)

    created = Automations::Scheduler.dispatch_due!(now: now)

    assert_equal 1, created.size
    assert_equal due.id, created.first.automation_id
    assert_nil AutomationRun.find_by(automation: paused)
    assert_nil AutomationRun.find_by(automation: later)
    assert_equal "#{due.id}:#{now.iso8601}", AutomationRun.find_by!(automation: due).dispatch_key

    assert_no_difference -> { AutomationRun.count } do
      created_again = Automations::Scheduler.dispatch_due!(now: now)
      assert_equal [created.first.id], created_again.map(&:id)
    end
  end

  private

    def create_automation!(status:, hour:, minute:)
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
        schedule_timezone: "UTC",
        task_payload: { "kind" => "scheduled_prompt", "prompt" => "Ship it" },
      )
    end
end
