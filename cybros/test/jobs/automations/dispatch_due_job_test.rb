require "test_helper"

class Automations::DispatchDueJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "perform dispatches due automations and enqueues execution jobs" do
    due = create_automation!(status: "active", hour: 9, minute: 0)
    create_automation!(status: "paused", hour: 9, minute: 0)

    assert_enqueued_with(job: Automations::ExecuteRunJob) do
      Automations::DispatchDueJob.perform_now(now: Time.utc(2026, 3, 9, 9, 0, 0))
    end

    run = AutomationRun.find_by!(automation: due)
    assert_equal "queued", run.status
    assert_equal [run.id], enqueued_jobs.last[:args]
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
