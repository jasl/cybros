require "test_helper"

class AutomationTest < ActiveSupport::TestCase
  test "defaults to a full-access scheduled automation with task payload storage" do
    automation = build_automation

    assert_predicate automation, :valid?
    automation.save!

    assert_equal "full_access", automation.permission_mode
    assert_equal "active", automation.status
    assert_equal "rrule", automation.schedule_kind
    assert_equal({ "kind" => "scheduled_prompt", "prompt" => "Ship it" }, automation.task_payload)
  end

  test "requires its runtime bindings and schedule definition" do
    automation = Automation.new

    refute_predicate automation, :valid?
    assert_includes automation.errors[:user], "must exist"
    assert_includes automation.errors[:agent_program], "must exist"
    assert_includes automation.errors[:execution_target], "must exist"
    assert_includes automation.errors[:schedule_kind], "can't be blank"
    assert_includes automation.errors[:task_payload], "must be a JSON object"

    automation.schedule_kind = "rrule"
    refute_predicate automation, :valid?
    assert_includes automation.errors[:schedule_rrule], "can't be blank"
    assert_includes automation.errors[:schedule_timezone], "can't be blank"
  end

  test "allows an optional conversation binding" do
    conversation = create_conversation!
    automation = build_automation(conversation: conversation)

    assert_predicate automation, :valid?
    automation.save!
    assert_equal conversation, automation.conversation
  end

  test "does not cascade-destroy immutable automation runs" do
    automation = build_automation
    automation.save!
    AutomationRun.create!(
      automation: automation,
      status: "queued",
      scheduled_for: Time.current.change(usec: 0),
      snapshot: { "automation" => { "permission_mode" => automation.permission_mode } },
    )

    assert_raises(ActiveRecord::DeleteRestrictionError) { automation.destroy }
    assert_equal 1, AutomationRun.where(automation: automation).count
  end

  private

    def build_automation(conversation: nil)
      Automation.new(
        user: create_user!,
        conversation: conversation,
        agent_program: create_program!,
        execution_target: create_execution_target!(name: "Automation target"),
        permission_mode: "full_access",
        status: "active",
        schedule_kind: "rrule",
        schedule_rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
        schedule_timezone: "UTC",
        task_payload: { "kind" => "scheduled_prompt", "prompt" => "Ship it" },
      )
    end

    def create_program!
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
    end

    def create_execution_target!(name:)
      location =
        ExecutionLocation.create!(
          name: "#{name} host",
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
          name: "#{name} workspace",
          root_path: "/tmp/#{name.parameterize}-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["automation"],
        )

      ExecutionTarget.create!(
        execution_location: location,
        workspace: workspace,
        name: name,
        status: "active",
        sandboxed: true,
      )
    end
end
