require "test_helper"

class ConversationDefaultExecutionTargetTest < ActionDispatch::IntegrationTest
  test "updates the conversation default execution target from the composer control" do
    user = sign_in_owner!
    current_target = create_execution_target!(name: "Current target")
    alternate_target = create_execution_target!(name: "Alternate target")
    conversation = create_conversation!(user: user, title: "Chat")
    conversation.update!(default_execution_target: current_target)

    patch conversation_path(conversation), params: { conversation: { default_execution_target_id: alternate_target.id } }

    assert_redirected_to conversation_path(conversation)
    assert_equal alternate_target.id, conversation.reload.default_execution_target_id

    follow_redirect!
    assert_response :success
    assert_select 'select[name="conversation[default_execution_target_id]"] option[selected]', text: "Alternate target"
  end

  test "rejects selecting an execution target that is not currently visible" do
    user = sign_in_owner!
    current_target = create_execution_target!(name: "Current target")
    inactive_target = create_execution_target!(name: "Inactive target", target_status: "inactive")
    conversation = create_conversation!(user: user, title: "Chat")
    conversation.update!(default_execution_target: current_target)

    patch conversation_path(conversation), params: { conversation: { default_execution_target_id: inactive_target.id } }

    assert_response :unprocessable_entity
    assert_equal current_target.id, conversation.reload.default_execution_target_id
  end

  test "show warns when the selected execution target is no longer available" do
    user = sign_in_owner!
    healthy_target = create_execution_target!(name: "Healthy target")
    stale_target = create_execution_target!(name: "Stale target", target_status: "inactive")
    conversation = create_conversation!(user: user, title: "Chat")
    conversation.update!(default_execution_target: stale_target)

    get conversation_path(conversation)

    assert_response :success
    assert_includes response.body, "Selected execution target is no longer available. Future runs will stay blocked until you choose another target or the operator restores this target."
    assert_select 'select[name="conversation[default_execution_target_id]"] option[selected]', text: stale_target.name
    assert_select 'select[name="conversation[default_execution_target_id]"] option', text: healthy_target.name
  end

  private

    def sign_in_owner!
      identity =
        Identity.create!(
          email: "admin@example.com",
          password: "Passw0rd",
          password_confirmation: "Passw0rd",
        )

      user = User.create!(identity: identity, role: :owner)

      post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
      assert_redirected_to root_path
      assert cookies[:session_token].present?

      user
    end

    def create_execution_target!(name:, target_status: "active")
      location =
        ExecutionLocation.create!(
          name: "#{name} host",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
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
          tags: ["fixture"],
        )

      ExecutionTarget.create!(
        execution_location: location,
        workspace: workspace,
        name: name,
        status: target_status,
        sandboxed: true,
      )
    end
end
