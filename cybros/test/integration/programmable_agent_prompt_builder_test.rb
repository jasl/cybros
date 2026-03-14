require "test_helper"
require_relative "../support/programmable_agent_runtime_test_support"

class ProgrammableAgentPromptBuilderTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProgrammableAgentRuntimeTestSupport

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "bundled claw sends lane prompt buffer sections through the actual model request" do
    llm_payloads = []
    llm_server =
      MockLLMServer.new do |payload|
        llm_payloads << payload.deep_dup
        MockLLMServer.chat_response(content: "llm draft answer")
      end.start

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      conversation = create_conversation!(title: "Prompt Builder")
      seed_prompt_buffer_entry!(conversation.chat_lane, buffer_name: "summaries", kind: "summary", content: "Carry forward the earlier refactor summary.")
      seed_prompt_buffer_entry!(conversation.chat_lane, buffer_name: "working_notes", kind: "note", content: "Preserve the placeholder replacement semantics.")
      seed_prompt_buffer_entry!(conversation.chat_lane, buffer_name: "handoff", kind: "handoff", content: "Next step is the runtime cutover verification pass.")

      run_bundled_claw_turn!(
        conversation: conversation,
        user_content: "Continue the runtime cutover",
        model_ref: "dev/mock-model",
        llm_payloads: llm_payloads,
      )

      system_prompt = llm_payloads.last.fetch("messages").find { |message| message["role"] == "system" }.fetch("content")

      assert_includes system_prompt, %(<lane_prompt_buffer name="system">)
      assert_includes system_prompt, %(<lane_prompt_buffer name="summaries">)
      assert_includes system_prompt, "Carry forward the earlier refactor summary."
      assert_includes system_prompt, %(<lane_prompt_buffer name="working_notes">)
      assert_includes system_prompt, "Preserve the placeholder replacement semantics."
      assert_includes system_prompt, %(<lane_prompt_buffer name="handoff">)
      assert_includes system_prompt, "Next step is the runtime cutover verification pass."
    end
  ensure
    llm_server&.shutdown
  end

  test "bundled claw drops working_notes from the model request before history when prompt budget is tight" do
    llm_payloads = []
    llm_server =
      MockLLMServer.new do |payload|
        llm_payloads << payload.deep_dup
        MockLLMServer.chat_response(content: "llm draft answer")
      end.start
    counter =
      AgentCore::Resources::TokenCounter::HeuristicWithOverhead.new(
        chars_per_token: 1.0,
        non_ascii_chars_per_token: 1.0,
        per_message_overhead: 0,
      )

    with_runtime_token_counter(counter) do
      with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url, context_window_tokens: 8_000)) do
        conversation = create_conversation!(title: "Prompt Budget")
        seed_prompt_buffer_entry!(conversation.chat_lane, buffer_name: "summaries", kind: "summary", content: "Keep this compact summary.")
        seed_prompt_buffer_entry!(conversation.chat_lane, buffer_name: "handoff", kind: "handoff", content: "Keep this handoff note.")
        seed_prompt_buffer_entry!(
          conversation.chat_lane,
          buffer_name: "working_notes",
          kind: "note",
          content: "Drop this working note first. " + ("x" * 12_000),
        )

        run_bundled_claw_turn!(
          conversation: conversation,
          user_content: "Continue the runtime cutover",
          model_ref: "dev/mock-model",
          llm_payloads: llm_payloads,
        )

        system_prompt = llm_payloads.last.fetch("messages").find { |message| message["role"] == "system" }.fetch("content")

        assert_includes system_prompt, "Keep this compact summary."
        assert_includes system_prompt, "Keep this handoff note."
        refute_includes system_prompt, "Drop this working note first."
      end
    end
  ensure
    llm_server&.shutdown
  end

  private

    def run_bundled_claw_turn!(conversation:, user_content:, model_ref:, llm_payloads:)
      result = conversation.append_user_message!(content: user_content, model_ref: model_ref)
      agent_node = result.fetch(:agent_node)

      conversation.root_graph.nodes.find(agent_node.id).update!(claim_after_at: nil)
      claimed = DAG::Scheduler.claim_executable_nodes(graph: conversation.root_graph, limit: 10, claimed_by: "test").map(&:id)
      assert_includes claimed, agent_node.id

      DAG::Runner.run_node!(agent_node.id)

      agent = conversation.root_graph.nodes.find(agent_node.id)
      run = ConversationRun.find_by!(conversation: conversation, dag_node_id: agent.id)

      assert_predicate llm_payloads, :any?
      assert_equal DAG::Node::FINISHED, agent.reload.state
      assert run.reload.succeeded?,
        "run_state=#{run.reload.state} run_error=#{run.reload.error.inspect} llm_payloads=#{llm_payloads.inspect}"

      [agent, run]
    end

    def seed_prompt_buffer_entry!(lane, buffer_name:, kind:, content:, seq: 10, priority: 100, estimated_tokens: 64)
      lane.lane_prompt_buffer_entries.create!(
        buffer_name: buffer_name,
        seq: seq,
        kind: kind,
        content: content,
        priority: priority,
        estimated_tokens: estimated_tokens,
        metadata: {},
      )
    end

    def with_runtime_token_counter(counter)
      singleton = Cybros::AgentRuntimeResolver.singleton_class
      singleton.alias_method :__programmable_agent_prompt_builder_original_token_counter_for_model_ref, :token_counter_for_model_ref
      singleton.define_method(:token_counter_for_model_ref) do |model_ref:|
        _ = model_ref
        counter
      end

      yield
    ensure
      if singleton.method_defined?(:__programmable_agent_prompt_builder_original_token_counter_for_model_ref)
        singleton.alias_method :token_counter_for_model_ref, :__programmable_agent_prompt_builder_original_token_counter_for_model_ref
        singleton.remove_method :__programmable_agent_prompt_builder_original_token_counter_for_model_ref
      end
    end

    def mock_llm_catalog_yaml(base_url:, context_window_tokens: 20_000)
      <<~YAML
        version: 1
        default_model_ref: "dev/mock-model"
        providers:
          dev:
            display_name: "Dev"
            enabled: true
            adapter_key: "dev"
            base_url: "#{base_url}"
            headers: {}
            requires_credential: false
            wire_api: "chat_completions"
            transport: "http"
            models:
              mock-model:
                display_name: "Mock"
                api_model: "mock-model"
                context_window_tokens: #{context_window_tokens}
                capabilities:
                  input: { text: true, image: false }
                  tools: { tool_calling: true }
                  protocol: "chat_completions"
      YAML
    end
end
