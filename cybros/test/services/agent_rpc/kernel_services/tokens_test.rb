require "test_helper"

class AgentRPC::KernelServices::TokensTest < ActiveSupport::TestCase
  test "estimate_text and estimate_messages delegate to the runtime token counter" do
    draft = create_prepared_draft!
    fake_counter =
      Struct.new(:counted_texts, :counted_messages) do
        def count_text(text)
          counted_texts << text
          11
        end

        def count_messages(messages)
          counted_messages << messages.map(&:content)
          29
        end
      end.new([], [])

    with_token_counter(fake_counter) do
      text_result = AgentRPC::KernelServices::Tokens.estimate_text(draft: draft, text: "hello world")
      messages_result =
        AgentRPC::KernelServices::Tokens.estimate_messages(
          draft: draft,
          messages: [
            { "role" => "user", "content" => "Ship it" },
            { "role" => "assistant", "content" => [{ "type" => "text", "text" => "Done" }] },
          ],
        )

      assert_equal 11, text_result.fetch("estimated_tokens")
      assert_equal 29, messages_result.fetch("estimated_tokens")
      assert_equal ["hello world"], fake_counter.counted_texts
      assert_equal "Ship it", fake_counter.counted_messages.first.first
      assert_instance_of Array, fake_counter.counted_messages.first.second
      assert_instance_of AgentCore::TextContent, fake_counter.counted_messages.first.second.first
      assert_equal "Done", fake_counter.counted_messages.first.second.first.text
    end
  end

  private

    def create_prepared_draft!
      conversation = create_conversation!
      agent = conversation.agent
      recognized_deployment = recognize_agent_runtime!(agent: agent)
      credential = LLMProviderCredential.find_by!(provider_key: "dev")

      create_run_draft!(
        conversation: conversation,
        agent: agent,
        recognized_deployment: recognized_deployment,
        trigger_snapshot: { "kind" => "user_turn", "dag_node_id" => SecureRandom.uuid },
        provider_credential: credential,
        selected_model_ref: "dev/mock-model",
        runtime_governors: runtime_governors_snapshot(provider_credential: credential, selected_model_ref: "dev/mock-model", agent: agent),
        agent_config_schema_fingerprint: conversation.agent_config_schema_fingerprint,
        planning: {},
        staged_public_settings_patch: {},
        staged_agent_config_patch: {},
        staged_kv_ops: [],
        staged_prompt_buffer_ops: [],
        approval_state: { "status" => "not_required" },
      )
    end

    def with_token_counter(counter)
      singleton = Cybros::AgentRuntimeResolver.singleton_class
      singleton.alias_method :__tokens_test_original_token_counter_for_model_ref, :token_counter_for_model_ref
      singleton.define_method(:token_counter_for_model_ref) do |model_ref:|
        _ = model_ref
        counter
      end

      yield
    ensure
      if singleton.method_defined?(:__tokens_test_original_token_counter_for_model_ref)
        singleton.alias_method :token_counter_for_model_ref, :__tokens_test_original_token_counter_for_model_ref
        singleton.remove_method :__tokens_test_original_token_counter_for_model_ref
      end
    end
end
