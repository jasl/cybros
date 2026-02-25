# frozen_string_literal: true

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
    assert_equal "gpt-4o-mini", Cybros::TokenEstimation.canonical_model_hint("openai/gpt-4o-mini")
  end
end
