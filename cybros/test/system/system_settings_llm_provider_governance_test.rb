require "application_system_test_case"

class SystemSettingsLlmProviderGovernanceSystemTest < ApplicationSystemTestCase
  setup do
    ProviderBudgetReservation.delete_all
    ConversationRun.update_all(provider_credential_id: nil)
    RunDraft.update_all(provider_credential_id: nil)
    LLMProvider.delete_all
  end

  test "owner can edit api key limiter settings from the browser" do
    owner = create_user!(email: "owner-provider@example.com")

    sign_in_as!(email: owner.identity.email)
    visit edit_system_settings_llm_provider_path("openai")

    assert_text "LLM Provider Credentials"

    fill_in "API key", with: "sk-browser"
    set_numeric_field!("Max concurrent requests", "6")
    set_numeric_field!("Requests per minute", "180")
    set_numeric_field!("Tokens per minute", "360000")
    set_numeric_field!("Burst limit", "10")
    fill_in "Backoff policy", with: <<~JSON
      {"kind":"exponential","base_delay_ms":900,"max_delay_ms":60000}
    JSON

    click_button "Save"

    assert_current_path edit_system_settings_llm_provider_path("openai")
    assert_text "Credentials updated"
    assert_field "Max concurrent requests", with: "6"
    assert_field "Requests per minute", with: "180"
    assert_field "Tokens per minute", with: "360000"
    assert_field "Burst limit", with: "10"

    provider = LLMProvider.find_by!(provider_key: "openai")
    assert_equal 6, provider.max_concurrent_requests
    assert_equal({ "kind" => "exponential", "base_delay_ms" => 900, "max_delay_ms" => 60_000 }, provider.backoff_policy)
  end

  test "admin can edit oauth limiter settings while preserving device flow controls" do
    admin = create_user!(role: :admin, email: "admin-provider@example.com")
    ensure_llm_provider!(
      provider_key: "codex_subscription",
      credential_type: "oauth_codex",
      access_token: "access-token",
      refresh_token: "refresh-token",
      expires_at: 2.hours.from_now,
      max_concurrent_requests: 4,
      requests_per_minute: 120,
      tokens_per_minute: 240_000,
      burst_limit: 8,
      backoff_policy: { "kind" => "exponential", "base_delay_ms" => 500, "max_delay_ms" => 30_000 },
    )

    sign_in_as!(email: admin.identity.email)
    visit edit_system_settings_llm_provider_path("codex_subscription")

    assert_text "Device flow"
    assert_button "Start"

    set_numeric_field!("Max concurrent requests", "2")
    set_numeric_field!("Requests per minute", "60")
    set_numeric_field!("Tokens per minute", "125000")
    set_numeric_field!("Burst limit", "4")
    fill_in "Backoff policy", with: <<~JSON
      {"kind":"linear","base_delay_ms":1250,"max_delay_ms":20000}
    JSON

    click_button "Save limiter settings"

    assert_current_path edit_system_settings_llm_provider_path("codex_subscription")
    assert_text "Credentials updated"
    assert_text "Connected"
    assert_button "Start"

    provider = LLMProvider.find_by!(provider_key: "codex_subscription")
    assert_equal 2, provider.max_concurrent_requests
    assert_equal "access-token", provider.access_token
    assert_equal({ "kind" => "linear", "base_delay_ms" => 1250, "max_delay_ms" => 20_000 }, provider.backoff_policy)
  end

  test "browser keeps the user on the edit surface when limiter input is invalid" do
    owner = create_user!(email: "owner-invalid-provider@example.com")

    sign_in_as!(email: owner.identity.email)
    visit edit_system_settings_llm_provider_path("openai")

    fill_in "API key", with: "sk-browser"
    set_numeric_field!("Max concurrent requests", "9")
    set_numeric_field!("Requests per minute", "300")
    set_numeric_field!("Tokens per minute", "500000")
    set_numeric_field!("Burst limit", "12")
    fill_in "Backoff policy", with: "[]"

    click_button "Save"

    assert_current_path edit_system_settings_llm_provider_path("openai")
    assert_text "Backoff policy must be a JSON object"
    assert_field "Max concurrent requests", with: "9"
    assert_field "Backoff policy", with: "[]"
  end

  private

    def set_numeric_field!(label, value)
      field = find_field(label)
      field.set(value)
      assert_field label, with: value
    end
end
