require "test_helper"

class Automations::DispatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "dispatch creates one queued automation run with durable schedule facts" do
    automation = create_automation!
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    dispatch_key = "#{automation.id}:#{scheduled_for.iso8601}"
    run = nil

    assert_enqueued_with(job: Automations::ExecuteRunJob) do
      run =
        Automations::Dispatch.call!(
          automation: automation,
          scheduled_for: scheduled_for,
          dispatch_key: dispatch_key,
          trigger_snapshot: { "kind" => "schedule", "scheduled_for" => scheduled_for.iso8601 },
        )
    end

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
    assert_equal [run.id], enqueued_jobs.last[:args]
  end

  test "dispatch does not enqueue duplicate execution work for the same logical trigger delivery" do
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

    clear_enqueued_jobs

    assert_no_difference -> { AutomationRun.count } do
      assert_no_enqueued_jobs do
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
  end

  test "dispatch stays retryable when execute job enqueue fails after run creation" do
    automation = create_automation!
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    dispatch_key = "#{automation.id}:#{scheduled_for.iso8601}"
    execute_job_singleton = Automations::ExecuteRunJob.singleton_class

    error =
      assert_raises(RuntimeError) do
        execute_job_singleton.alias_method :__dispatch_test_original_perform_later__, :perform_later
        execute_job_singleton.define_method(:perform_later) { |_automation_run_id| raise "enqueue failed" }

        begin
          Automations::Dispatch.call!(
            automation: automation,
            scheduled_for: scheduled_for,
            dispatch_key: dispatch_key,
            trigger_snapshot: { "kind" => "schedule", "scheduled_for" => scheduled_for.iso8601 },
          )
        ensure
          execute_job_singleton.alias_method :perform_later, :__dispatch_test_original_perform_later__
          execute_job_singleton.remove_method :__dispatch_test_original_perform_later__
        end
      end

    assert_equal "enqueue failed", error.message
    assert_nil AutomationRun.find_by(automation: automation, dispatch_key: dispatch_key)
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
