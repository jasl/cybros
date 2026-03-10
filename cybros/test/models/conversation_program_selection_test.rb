require "test_helper"

class ConversationProgramSelectionTest < ActiveSupport::TestCase
  test "new conversations default to the bundled default agent program" do
    default_program = AgentPrograms::BootstrapBundledDefaultService.ensure_program!
    conversation = Conversation.new(title: "Conversation", user: create_user!)

    assert_predicate conversation, :valid?
    assert_equal default_program.id, conversation.agent_program_id
    assert_equal default_program.config_schema_fingerprint, conversation.agent_config_schema_fingerprint
  end
end
