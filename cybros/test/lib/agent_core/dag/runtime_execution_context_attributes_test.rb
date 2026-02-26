require "test_helper"

class AgentCore::DAG::RuntimeExecutionContextAttributesTest < Minitest::Test
  def build_runtime(**kwargs)
    AgentCore::DAG::Runtime.new(
      provider: Object.new,
      model: "test-model",
      tools_registry: AgentCore::Resources::Tools::Registry.new,
      **kwargs,
    )
  end

  def test_execution_context_attributes_requires_symbol_keys
    err =
      assert_raises(AgentCore::ValidationError) do
        build_runtime(execution_context_attributes: { "cwd" => "/tmp" })
      end

    assert_equal "agent_core.dag.runtime.execution_context_attributes_keys_must_be_symbols_got", err.code
  end

  def test_execution_context_attributes_agent_requires_hash
    err =
      assert_raises(AgentCore::ValidationError) do
        build_runtime(execution_context_attributes: { agent: "oops" })
      end

    assert_equal "agent_core.dag.runtime.execution_context_attributes_agent_must_be_a_hash", err.code
  end

  def test_execution_context_attributes_agent_nested_keys_require_symbols
    err =
      assert_raises(AgentCore::ValidationError) do
        build_runtime(execution_context_attributes: { agent: { "key" => "main" } })
      end

    assert_equal "agent_core.dag.runtime.execution_context_attributes_agent_keys_must_be_symbols_got", err.code
  end

  def test_runtime_with_does_not_raise
    runtime = build_runtime
    updated = runtime.with(llm_options: { stream: false })
    assert_equal({ stream: false }, updated.llm_options)
  end

  def test_tool_name_normalize_index_requires_hash
    err =
      assert_raises(AgentCore::ValidationError) do
        build_runtime(tool_name_normalize_index: [])
      end

    assert_equal "agent_core.dag.runtime.tool_name_normalize_index_must_be_a_hash", err.code
  end

  def test_runtime_with_preserves_normalize_index_when_enabled
    runtime = build_runtime(tool_name_normalize_fallback: true)
    refute_nil runtime.tool_name_normalize_index

    updated = runtime.with(llm_options: { stream: false })
    assert_instance_of Hash, updated.tool_name_normalize_index
  end
end
