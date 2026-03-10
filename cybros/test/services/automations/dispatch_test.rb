require "test_helper"

class Automations::DispatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "dispatch creates one queued execution conversation with durable trigger facts" do
    automation = create_automation!
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    dispatch_key = "#{automation.id}:#{scheduled_for.iso8601}"
    conversation = nil

    assert_enqueued_with(job: Automations::ExecuteConversationJob) do
      conversation =
        Automations::Dispatch.call!(
          automation: automation,
          scheduled_for: scheduled_for,
          dispatch_key: dispatch_key,
          trigger_snapshot: { "kind" => "schedule", "scheduled_for" => scheduled_for.iso8601 },
        )
    end

    assert_equal automation.id, conversation.automation_id
    assert_equal automation.user_id, conversation.user_id
    assert_equal automation.agent_program_id, conversation.agent_program_id
    assert_equal automation.execution_target_id, conversation.default_execution_target_id
    assert_equal "full_access", conversation.permission_mode
    assert_equal dispatch_key, conversation.automation_dispatch_key
    assert_equal scheduled_for, conversation.automation_triggered_at
    assert_equal "queued", conversation.metadata.dig("automation_execution", "status")
    assert_equal dispatch_key, conversation.metadata.dig("automation_execution", "dispatch_key")
    assert_equal automation.id, conversation.metadata.dig("automation", "id")
    assert_equal automation.agent_program_id, conversation.metadata.dig("automation", "agent_program_id")
    assert_equal automation.execution_target_id, conversation.metadata.dig("automation", "execution_target_id")
    assert_equal "rrule", conversation.metadata.dig("schedule", "kind")
    assert_equal automation.schedule_rrule, conversation.metadata.dig("schedule", "rrule")
    assert_equal automation.schedule_timezone, conversation.metadata.dig("schedule", "timezone")
    assert_equal scheduled_for.iso8601, conversation.metadata.dig("schedule", "scheduled_for")
    assert_equal "schedule", conversation.metadata.dig("trigger", "kind")
    assert_equal [conversation.id], enqueued_jobs.last[:args]
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

    assert_no_difference -> { Conversation.count } do
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

  test "dispatch requires a non-blank dispatch key" do
    automation = create_automation!
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)

    error =
      assert_raises(AgentCore::ValidationError) do
        Automations::Dispatch.call!(
          automation: automation,
          scheduled_for: scheduled_for,
          dispatch_key: "   ",
          trigger_snapshot: { "kind" => "schedule", "scheduled_for" => scheduled_for.iso8601 },
        )
      end

    assert_equal "cybros.automations.dispatch_key_missing", error.code
    assert_nil Conversation.find_by(automation: automation)
    assert_no_enqueued_jobs
  end

  test "dispatch stays retryable when execute job enqueue fails after run creation" do
    automation = create_automation!
    scheduled_for = Time.utc(2026, 3, 9, 9, 0, 0)
    dispatch_key = "#{automation.id}:#{scheduled_for.iso8601}"
    execute_job_singleton = Automations::ExecuteConversationJob.singleton_class

    error =
      assert_raises(RuntimeError) do
        execute_job_singleton.alias_method :__dispatch_test_original_perform_later__, :perform_later
        execute_job_singleton.define_method(:perform_later) { |_conversation_id| raise "enqueue failed" }

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
    assert_nil Conversation.find_by(automation: automation, automation_dispatch_key: dispatch_key)
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
        task_payload: {
          "kind" => "scheduled_prompt",
          "prompt" => "Ship it",
          "selected_model_ref" => "openai/gpt-5.4",
        },
      )
    end
end
