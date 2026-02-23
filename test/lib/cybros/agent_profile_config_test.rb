# frozen_string_literal: true

require "test_helper"

class Cybros::AgentProfileConfigTest < Minitest::Test
  def test_parses_a_valid_config_hash_and_round_trips_metadata
    cfg =
      Cybros::AgentProfileConfig.from_value(
        {
          "base" => "coding",
          "context_turns" => 12,
          "prompt_mode" => "minimal",
          "memory_search_limit" => 0,
          "tools_allowed" => ["memory_*"],
          "repo_docs_enabled" => false,
          "repo_docs_max_total_bytes" => 10_000,
        },
      )

    assert_equal "coding", cfg.base_profile
    assert_equal 12, cfg.context_turns
    assert_equal :minimal, cfg.prompt_mode
    assert_equal 0, cfg.memory_search_limit
    assert_equal ["memory_*"], cfg.tools_allowed
    assert_equal false, cfg.repo_docs_enabled
    assert_equal 10_000, cfg.repo_docs_max_total_bytes

    assert_equal(
      {
        "base" => "coding",
        "context_turns" => 12,
        "prompt_mode" => "minimal",
        "memory_search_limit" => 0,
        "tools_allowed" => ["memory_*"],
        "repo_docs_enabled" => false,
        "repo_docs_max_total_bytes" => 10_000,
      },
      cfg.to_metadata,
    )
  end

  def test_rejects_unknown_keys
    err =
      assert_raises(AgentCore::ValidationError) do
        Cybros::AgentProfileConfig.from_value({ "base" => "coding", "wat" => 1 })
      end

    assert_equal "cybros.agent_profile_config.agent_profile_contains_unknown_keys", err.code
  end
end
