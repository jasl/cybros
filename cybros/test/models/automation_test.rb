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
    assert_includes automation.errors[:base], "must define exactly one schedule or trigger"
    assert_includes automation.errors[:task_payload], "must be a JSON object"
  end

  test "allows an optional conversation binding" do
    conversation = create_conversation!
    automation = build_automation(conversation: conversation)

    assert_predicate automation, :valid?
    automation.save!
    assert_equal conversation, automation.conversation
  end

  test "requires conversation binding to belong to the automation owner" do
    owner = create_user!
    other_user = create_user!
    conversation = create_conversation!(user: other_user)
    automation = build_automation(user: owner, conversation: conversation)

    refute_predicate automation, :valid?
    assert_includes automation.errors[:conversation], "must belong to the automation owner"
  end

  test "rejects invalid schedule definitions" do
    automation = build_automation(schedule_rrule: "nonsense", schedule_timezone: "Mars/Olympus")

    refute_predicate automation, :valid?
    assert_includes automation.errors[:schedule_rrule], "must be a supported RRULE"
    assert_includes automation.errors[:schedule_timezone], "must be a valid time zone"
  end

  test "rejects rrules with out-of-range schedule fields" do
    automation = build_automation(schedule_rrule: "FREQ=DAILY;BYHOUR=99;BYMINUTE=0")

    refute_predicate automation, :valid?
    assert_includes automation.errors[:schedule_rrule], "must be a supported RRULE"
  end

  test "allows trigger-based automations without schedule fields" do
    automation =
      build_automation(
        schedule_kind: nil,
        schedule_rrule: nil,
        schedule_timezone: nil,
        trigger_kind: "event",
        trigger_payload: { "source" => "conversation.message.created" },
      )

    assert_predicate automation, :valid?
    automation.save!
    assert_equal "event", automation.trigger_kind
    assert_equal({ "source" => "conversation.message.created" }, automation.trigger_payload)
  end

  test "does not cascade-destroy immutable automation runs" do
    automation = build_automation
    automation.save!
    AutomationRun.create!(
      automation: automation,
      dispatch_key: "#{automation.id}:#{Time.current.change(usec: 0).iso8601}",
      status: "queued",
      scheduled_for: Time.current.change(usec: 0),
      snapshot: { "automation" => { "permission_mode" => automation.permission_mode } },
    )

    assert_raises(ActiveRecord::DeleteRestrictionError) { automation.destroy }
    assert_equal 1, AutomationRun.where(automation: automation).count
  end

  private

    def build_automation(
      user: nil,
      conversation: nil,
      schedule_kind: "rrule",
      schedule_rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
      schedule_timezone: "UTC",
      trigger_kind: nil,
      trigger_payload: nil
    )
      resolved_user = user || conversation&.user || create_user!

      Automation.new(
        user: resolved_user,
        conversation: conversation,
        agent_program: create_program!,
        execution_target: create_execution_target!(name: "Automation target"),
        permission_mode: "full_access",
        status: "active",
        schedule_kind: schedule_kind,
        schedule_rrule: schedule_rrule,
        schedule_timezone: schedule_timezone,
        trigger_kind: trigger_kind,
        trigger_payload: trigger_payload,
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
