require "test_helper"

class LlmProvidersTest < ActionDispatch::IntegrationTest
  setup do
    LLMProvider.delete_all
  end

  def with_stubbed_singleton_method(obj, method_name, value:)
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

    identity
  end

  def sign_in_member!
    identity =
      Identity.create!(
        email: "member@example.com",
        password: "Passw0rd",
        password_confirmation: "Passw0rd",
      )

    User.create!(identity: identity, role: :member)

    post session_path, params: { email: "member@example.com", password: "Passw0rd" }
    assert_redirected_to root_path
    assert cookies[:session_token].present?

    identity
  end

  test "requires authentication" do
    get system_settings_llm_providers_path
    assert_redirected_to new_session_path
  end

  test "requires owner or admin" do
    sign_in_member!
    get system_settings_llm_providers_path
    assert_response :forbidden
  end

  test "index lists providers" do
    sign_in_owner!
    Account.instance.update_llm_default_model_ref!("")

    get system_settings_llm_providers_path
    assert_response :success
    assert_includes response.body, "OpenAI"
    assert_includes response.body, "codex_subscription"
    assert_includes response.body, "Catalog default: openai/gpt-5.4"
    assert_includes response.body, "Use catalog default: openai/gpt-5.4"
  end

  test "update stores encrypted api_key credential (provider_key keyed)" do
    sign_in_owner!
    LLMProvider.delete_all

    assert_difference -> { LLMProvider.count }, +1 do
      patch system_settings_llm_provider_path("openai"), params: {
        llm_provider: {
          api_key: "sk-test",
        },
      }
    end

    provider = LLMProvider.find_by!(provider_key: "openai")
    assert_redirected_to edit_system_settings_llm_provider_path("openai")
    assert_equal "sk-test", provider.api_key
    assert_equal "api_key", provider.credential_type

    raw =
      LLMProvider.lease_connection.select_value(
        LLMProvider.send(
          :sanitize_sql_array,
          ["SELECT api_key FROM llm_providers WHERE provider_key = ?", "openai"],
        ),
      ).to_s
    refute_equal "sk-test", raw
    refute_includes raw, "sk-test"
  end

  test "update_default_model stores and clears a site-wide default model" do
    sign_in_owner!
    Account.instance.update_llm_default_model_ref!("")
    ensure_llm_provider!(provider_key: "openai", credential_type: "api_key", api_key: "sk-test")

    patch default_model_system_settings_llm_providers_path, params: { default_model_ref: "openai/gpt-5.4" }
    assert_redirected_to system_settings_llm_providers_path
    assert_equal "openai/gpt-5.4", Account.instance.settings.dig("llm", "default_model_ref")

    get system_settings_llm_providers_path
    assert_response :success
    assert_includes response.body, "Site override: openai/gpt-5.4"

    patch default_model_system_settings_llm_providers_path, params: { default_model_ref: "" }
    assert_redirected_to system_settings_llm_providers_path
    assert_nil Account.instance.settings.dig("llm", "default_model_ref")
  end

  test "update_default_model rejects model refs that are not currently usable" do
    sign_in_owner!
    Account.instance.update_llm_default_model_ref!("")

    patch default_model_system_settings_llm_providers_path, params: { default_model_ref: "openai/gpt-5.4" }
    assert_response :unprocessable_entity
    assert_includes response.body, "Default model must be currently usable"
    assert_nil Account.instance.settings.dig("llm", "default_model_ref")
  end

  test "update_default_model rejects clearing to an unusable catalog default" do
    sign_in_owner!
    ensure_llm_provider!(provider_key: "openrouter", credential_type: "api_key", api_key: "sk-test")
    Account.instance.update_llm_default_model_ref!("openrouter/openai-gpt-5.4-pro")

    patch default_model_system_settings_llm_providers_path, params: { default_model_ref: "" }

    assert_response :unprocessable_entity
    assert_includes response.body, "Catalog default is not currently usable."
    assert_equal "openrouter/openai-gpt-5.4-pro", Account.instance.settings.dig("llm", "default_model_ref")
  end

  test "index flags a stored site default that is not currently usable" do
    sign_in_owner!
    Account.instance.update_llm_default_model_ref!("openai/gpt-5.4")
    LLMProvider.delete_all

    get system_settings_llm_providers_path
    assert_response :success
    assert_includes response.body, "Stored site default is not currently usable."
    assert_includes response.body, "Site override: openai/gpt-5.4"
  end

  test "index excludes codex models from the default selector when oauth credentials are not runtime-usable" do
    sign_in_owner!
    ensure_llm_provider!(provider_key: "codex_subscription", credential_type: "oauth_codex", access_token: "at-only")

    get system_settings_llm_providers_path
    assert_response :success
    refute_includes response.body, 'value="codex_subscription/gpt-5.4"'
  end

  test "index includes codex models when oauth access token has a future expiry" do
    sign_in_owner!
    ensure_llm_provider!(
      provider_key: "codex_subscription",
      credential_type: "oauth_codex",
      access_token: "at-valid",
      expires_at: 2.hours.from_now,
    )

    get system_settings_llm_providers_path

    assert_response :success
    assert_includes response.body, 'value="codex_subscription/gpt-5.4"'
  end

  test "dev provider routes are unavailable outside development and test" do
    sign_in_owner!
    production_env = ActiveSupport::StringInquirer.new("production")

    with_stubbed_singleton_method(Rails, :env, value: production_env) do
      get edit_system_settings_llm_provider_path("dev")
    end

    assert_response :not_found
  end
end
