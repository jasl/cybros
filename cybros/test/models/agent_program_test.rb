require "test_helper"

class AgentProgramTest < ActiveSupport::TestCase
  test "persists contract ownership fields" do
    program = build_program

    assert_predicate program, :valid?
    program.save!

    assert_equal "fixture.program", program.config_namespace
    assert_equal "contract:v1", program.published_contract_fingerprint
    assert_equal({ "name" => "Fixture" }, program.manifest_snapshot)
    assert_equal({ "enabled" => true }, program.global_config)
  end

  test "enforces unique config namespaces when present" do
    build_program.save!

    duplicate = build_program(name: "Fixture Two")

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:config_namespace], "has already been taken"
  end

  test "restricts deletion when runtime records still reference the program" do
    program = build_program
    program.save!

    conversation = Conversation.create!(user: create_user!, title: "Chat", agent_program: program)

    assert_raises(ActiveRecord::DeleteRestrictionError) do
      program.destroy!
    end
  end

  test "bundled programs require bundled_agent_key" do
    program =
      build_program(
        source_kind: "bundled",
        bundled_agent_key: "",
        local_path: "agents/default",
      )

    refute_predicate program, :valid?
    assert_includes program.errors[:bundled_agent_key], "can't be blank"
  end

  test "bundled programs must point at the canonical bundled source root" do
    program =
      build_program(
        source_kind: "bundled",
        bundled_agent_key: "default",
        local_path: "agents/floating",
      )

    refute_predicate program, :valid?
    assert_includes program.errors[:local_path], "must match the bundled source root for this key"
  end

  private

  def build_program(attributes = {})
    AgentProgram.new(
      {
        name: "Fixture Program",
        config_namespace: "fixture.program",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: { "name" => "Fixture" },
        global_config: { "enabled" => true },
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
        source_kind: "custom",
      }.merge(attributes),
    )
  end
end
