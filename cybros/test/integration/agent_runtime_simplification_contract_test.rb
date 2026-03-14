require "test_helper"

class AgentRuntimeSimplificationContractTest < ActiveSupport::TestCase
  test "conversation runtime surface binds conversations to agents and turns to recognized deployments" do
    assert_equal :agent, Conversation.reflect_on_association(:agent)&.name
    assert_nil Conversation.reflect_on_association(:agent_program)
    assert_equal :recognized_deployment, RunDraft.reflect_on_association(:recognized_deployment)&.name
    assert_equal :recognized_deployment, ConversationRun.reflect_on_association(:recognized_deployment)&.name
    assert_nil RunDraft.reflect_on_association(:agent_deployment)
    assert_nil ConversationRun.reflect_on_association(:agent_deployment)
  end

  test "recognized deployment keys are part of the immutable turn contract" do
    assert_includes RunDraft.attribute_names, "recognized_deployment_key"
    assert_includes ConversationRun.attribute_names, "recognized_deployment_key"
    assert_includes ConversationRun::SNAPSHOT_FIELDS, :recognized_deployment_id
    assert_includes ConversationRun::SNAPSHOT_FIELDS, :recognized_deployment_key
  end

  test "planning no longer requires a public execution target selection" do
    conversation = Conversation.create!(user: create_user!, title: "Chat")

    error = nil
    begin
      RuntimeGovernance::DraftGovernorResolver.resolve!(
        entrypoint: conversation,
        selected_model_ref: "dev/mock-model",
      )
    rescue StandardError => e
      error = e
    end

    assert_nil error
  end
end
