require "test_helper"
require "fileutils"
require "tmpdir"

class CybrosTokenEstimationTest < ActiveSupport::TestCase
  test "registry skips missing hf tokenizer files by default" do
    Dir.mktmpdir do |dir|
      registry = Cybros::TokenEstimation.registry(tokenizer_root_path: dir)

      assert_equal "tiktoken", registry.dig("gpt-5.2", "tokenizer_family")
      assert_nil registry["deepseek-v3"]
    end
  end

  test "registry includes hf tokenizer when tokenizer file exists" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "deepseek-v3", "tokenizer.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{}")

      registry = Cybros::TokenEstimation.registry(tokenizer_root_path: dir)

      assert_equal "hf_tokenizers", registry.dig("deepseek-v3", "tokenizer_family")
      assert_equal path, registry.dig("deepseek-v3", "tokenizer_path")
    end
  end

  test "canonical_model_hint normalizes openai/ prefix" do
    assert_equal "gpt-5.4", Cybros::TokenEstimation.canonical_model_hint("openai/gpt-5.4")
  end

  test "registry includes current openai-family tokenizer hints used by catalog" do
    Dir.mktmpdir do |dir|
      registry = Cybros::TokenEstimation.registry(tokenizer_root_path: dir)
      estimator = Cybros::TokenEstimation.estimator(tokenizer_root_path: dir)

      assert_equal "tiktoken", registry.dig("gpt-5.4-pro", "tokenizer_family")
      assert_equal "tiktoken", registry.dig("gpt-5.3-chat", "tokenizer_family")
      assert_equal "tiktoken", registry.dig("gpt-5.3-chat-latest", "tokenizer_family")

      gpt_54 = estimator.describe(model_hint: "gpt-5.4")
      assert_equal "o200k_base", gpt_54.fetch(:encoding).to_s
      assert_equal "registry_encoding", gpt_54.fetch(:source).to_s
      assert_equal "o200k_base", gpt_54.fetch(:registry_encoding_name).to_s

      assert_equal "o200k_base", estimator.describe(model_hint: "gpt-5.4-pro").fetch(:encoding).to_s
      assert_equal "o200k_base", estimator.describe(model_hint: "gpt-5.3-chat").fetch(:encoding).to_s
    end
  end

  test "registry rejects invalid explicit tiktoken encoding names" do
    error =
      assert_raises(AgentCore::ValidationError) do
        Cybros::TokenEstimation.send(:validate_tiktoken_encoding_name!, "not-a-real-encoding", hint: "bad-gpt")
      end

    assert_equal "cybros.token_estimation.encoding_name_is_invalid", error.code
  end
end
