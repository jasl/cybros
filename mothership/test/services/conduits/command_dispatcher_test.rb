require "test_helper"

class Conduits::CommandDispatcherTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "dispatch-test")
    @territory = Conduits::Territory.create!(
      account: @account, name: "mobile-1", kind: "mobile",
      capabilities: ["camera.snap"]
    )
    @territory.activate!
    @dispatcher = Conduits::CommandDispatcher.new
  end

  test "dispatch returns :poll when territory has no websocket or push token" do
    command = create_command

    result = @dispatcher.dispatch(command)

    assert_equal :poll, result
    assert_equal "queued", command.reload.state
  end

  test "dispatch via websocket marks command dispatched and broadcasts" do
    @territory.update!(websocket_connected_at: Time.current)
    command = create_command

    # TerritoryChannel.broadcast_to is a no-op without a real cable connection,
    # but should not raise
    result = @dispatcher.dispatch(command)

    assert_equal :websocket, result
    assert_equal "dispatched", command.reload.state
    assert command.dispatched_at.present?
  end

  test "dispatch via push notification marks command dispatched" do
    @territory.update!(push_token: "fake-token", push_platform: "apns")
    command = create_command

    result = @dispatcher.dispatch(command)

    assert_equal :push_notification, result
    assert_equal "dispatched", command.reload.state
  end

  test "dispatch handles AASM::InvalidTransition gracefully" do
    command = create_command
    command.dispatch! # already dispatched

    # Trying to dispatch again should not raise
    result = @dispatcher.dispatch(command)

    assert_equal :poll, result
  end

  test "websocket dispatch prefers websocket over push notification" do
    @territory.update!(
      websocket_connected_at: Time.current,
      push_token: "fake-token",
      push_platform: "apns"
    )
    command = create_command

    result = @dispatcher.dispatch(command)

    assert_equal :websocket, result
  end

  private

  def create_command
    Conduits::Command.create!(
      account: @account,
      territory: @territory,
      capability: "camera.snap",
      params: { quality: 80 },
      timeout_seconds: 30
    )
  end
end
