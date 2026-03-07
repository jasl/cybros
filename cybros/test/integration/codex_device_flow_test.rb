require "test_helper"

class CodexDeviceFlowTest < ActionDispatch::IntegrationTest
  def with_stubbed_singleton_method(obj, method_name, value: nil)
    original = obj.method(method_name)
    obj.define_singleton_method(method_name) { |*_args, **_kwargs| value }
    yield
  ensure
    obj.define_singleton_method(method_name) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
  end

  def sign_in_owner!
    identity =
      Identity.create!(
        email: "admin@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    User.create!(identity: identity, role: :owner)

    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "device flow start stores flow in session and shows code on edit page" do
    sign_in_owner!

    flow = {
      "device_auth_id" => "dc",
      "user_code" => "UC-1234",
      "verification_uri" => "https://auth.openai.com/codex/device",
      "interval" => 5,
      "expires_at" => (Time.current + 300).iso8601,
    }

    with_stubbed_singleton_method(Cybros::LLM::CodexOAuth, :start_device_flow!, value: flow) do
      post device_flow_start_system_settings_llm_provider_path("codex_subscription")
    end

    assert_redirected_to edit_system_settings_llm_provider_path("codex_subscription")

    get edit_system_settings_llm_provider_path("codex_subscription")
    assert_response :success
    assert_includes response.body, "UC-1234"
    assert_includes response.body, "auth.openai.com/codex/device"
    assert_includes response.body, ">Poll<"
    assert_includes response.body, ">Start<"
  end

  test "device flow poll persists tokens when authorized" do
    sign_in_owner!

    # Prime session with a started device flow
    flow = {
      "device_auth_id" => "dc",
      "user_code" => "UC-1234",
      "verification_uri" => "https://auth.openai.com/codex/device",
      "interval" => 5,
      "expires_at" => (Time.current + 300).iso8601,
    }

    with_stubbed_singleton_method(Cybros::LLM::CodexOAuth, :start_device_flow!, value: flow) do
      post device_flow_start_system_settings_llm_provider_path("codex_subscription")
    end

    poll_result =
      {
        status: :authorized,
        tokens: {
          "access_token" => "at",
          "refresh_token" => "rt",
          "expires_at" => Time.current + 3600,
        },
        raw: {},
      }

    with_stubbed_singleton_method(Cybros::LLM::CodexOAuth, :poll_device_flow!, value: poll_result) do
      post device_flow_poll_system_settings_llm_provider_path("codex_subscription")
    end

    assert_redirected_to edit_system_settings_llm_provider_path("codex_subscription")

    cred = LLMProvider.find_by!(provider_key: "codex_subscription")
    assert_equal "oauth_codex", cred.credential_type
    assert_equal "at", cred.access_token
    assert_equal "rt", cred.refresh_token
  end

  test "signing in again clears stale device flow session state" do
    sign_in_owner!

    flow = {
      "device_auth_id" => "dc-stale",
      "user_code" => "UC-STALE",
      "verification_uri" => "https://auth.openai.com/codex/device",
      "interval" => 5,
      "expires_at" => (Time.current + 300).iso8601,
    }

    with_stubbed_singleton_method(Cybros::LLM::CodexOAuth, :start_device_flow!, value: flow) do
      post device_flow_start_system_settings_llm_provider_path("codex_subscription")
    end

    Session.delete_all
    post session_path, params: { email: "admin@example.com", password: "Passw0rd" }
    assert_redirected_to root_path

    get edit_system_settings_llm_provider_path("codex_subscription")
    assert_response :success
    refute_includes response.body, "UC-STALE"
    refute_includes response.body, ">Poll<"
    assert_includes response.body, ">Start<"
  end

  test "terminal poll failure clears the stale device flow session state" do
    sign_in_owner!

    flow = {
      "device_auth_id" => "dc-bad",
      "user_code" => "UC-BAD",
      "verification_uri" => "https://auth.openai.com/codex/device",
      "interval" => 5,
      "expires_at" => (Time.current + 300).iso8601,
    }

    with_stubbed_singleton_method(Cybros::LLM::CodexOAuth, :start_device_flow!, value: flow) do
      post device_flow_start_system_settings_llm_provider_path("codex_subscription")
    end

    original = Cybros::LLM::CodexOAuth.method(:poll_device_flow!)
    Cybros::LLM::CodexOAuth.define_singleton_method(:poll_device_flow!) do |**_kwargs|
      raise Cybros::LLM::CodexOAuthError.new("invalid grant", error_code: "invalid_grant")
    end

    post device_flow_poll_system_settings_llm_provider_path("codex_subscription")
    assert_redirected_to edit_system_settings_llm_provider_path("codex_subscription")
  ensure
    Cybros::LLM::CodexOAuth.define_singleton_method(:poll_device_flow!) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) } if original

    get edit_system_settings_llm_provider_path("codex_subscription")
    assert_response :success
    refute_includes response.body, "UC-BAD"
    refute_includes response.body, ">Poll<"
    assert_includes response.body, ">Start<"
  end

  test "edit ignores expired device flow session state and renders start without stale code" do
    sign_in_owner!

    expired_flow = {
      "device_auth_id" => "dc-old",
      "user_code" => "UC-OLD",
      "verification_uri" => "https://auth.openai.com/codex/device",
      "interval" => 5,
      "expires_at" => (Time.current - 60).iso8601,
    }

    with_stubbed_singleton_method(Cybros::LLM::CodexOAuth, :start_device_flow!, value: expired_flow) do
      post device_flow_start_system_settings_llm_provider_path("codex_subscription")
    end

    get edit_system_settings_llm_provider_path("codex_subscription")
    assert_response :success
    refute_includes response.body, "UC-OLD"
    refute_includes response.body, ">Poll<"
    assert_includes response.body, ">Start<"
  end
end
