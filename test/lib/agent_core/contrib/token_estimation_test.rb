# frozen_string_literal: true

require "test_helper"

class AgentCoreContribTokenEstimationTest < ActiveSupport::TestCase
  test "register! validates hf_tokenizers require tokenizer_path" do
    err =
      assert_raises(AgentCore::ValidationError) do
        AgentCore::Contrib::TokenEstimation.register!(
          {},
          hint: "deepseek-v3",
          tokenizer_family: :hf_tokenizers,
        )
      end

    assert_equal "agent_core.contrib.token_estimation.tokenizer_path_is_required_for_family", err.code
  end

  test "registry builds normalized entries" do
    registry =
      AgentCore::Contrib::TokenEstimation.registry(
        sources: [
          { hint: "gpt-5.2", tokenizer_family: :tiktoken },
          {
            "hint" => "deepseek-v3",
            "tokenizer_family" => "hf_tokenizers",
            "tokenizer_path" => "/tmp/deepseek-v3/tokenizer.json",
            "source_repo" => "deepseek-ai/DeepSeek-V3-0324",
          },
        ],
      )

    assert_equal "tiktoken", registry.dig("gpt-5.2", "tokenizer_family")
    assert_equal "gpt-5.2", registry.dig("gpt-5.2", "source_hint")

    assert_equal "hf_tokenizers", registry.dig("deepseek-v3", "tokenizer_family")
    assert_equal "/tmp/deepseek-v3/tokenizer.json", registry.dig("deepseek-v3", "tokenizer_path")
    assert_equal "deepseek-ai/DeepSeek-V3-0324", registry.dig("deepseek-v3", "source_repo")
  end
end
