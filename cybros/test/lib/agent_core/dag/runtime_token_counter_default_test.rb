require "test_helper"

class AgentCoreDAGRuntimeTokenCounterDefaultTest < ActiveSupport::TestCase
  test "defaults token_counter to estimator" do
    runtime =
      AgentCore::DAG::Runtime.new(
        provider: AgentCore::Resources::Provider::SimpleInferenceProvider.new(base_url: nil, api_key: nil),
        model: "gpt-4o-mini",
        tools_registry: AgentCore::Resources::Tools::Registry.new,
      )

    assert_instance_of AgentCore::Resources::TokenCounter::Estimator, runtime.token_counter
    assert_equal 4, runtime.token_counter.per_message_overhead
  end
end
