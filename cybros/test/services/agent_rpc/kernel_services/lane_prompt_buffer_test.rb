require "test_helper"

class AgentRPC::KernelServices::LanePromptBufferTest < ActiveSupport::TestCase
  test "put/list/get/delete/clear/snapshot operate on the active lane view and compute estimated tokens" do
    draft = create_prepared_draft!
    lane = draft.bound_lane

    persisted =
      LanePromptBufferEntry.create!(
        lane: lane,
        buffer_name: "summaries",
        seq: 10,
        kind: "summary",
        content: "Persisted summary",
        priority: 1,
        estimated_tokens: 5,
        metadata: { "source" => "seed" },
      )

    fake_counter = Struct.new(:seen_texts) do
      def count_text(text)
        seen_texts << text
        17
      end
    end.new([])

    with_token_counter(fake_counter) do
      result =
        AgentRPC::KernelServices::LanePromptBuffer.put!(
          draft: draft,
          buffer_name: "summaries",
          kind: "summary",
          content: "Fresh summary",
          priority: 9,
          metadata: { source: "agent" },
        )

      entry = result.fetch("entry")

      assert_equal ["Fresh summary"], fake_counter.seen_texts
      assert_equal "summaries", entry.fetch("buffer_name")
      assert_equal 20, entry.fetch("seq")
      assert_equal 17, entry.fetch("estimated_tokens")
      assert_equal({ "source" => "agent" }, entry.fetch("metadata"))

      listed_entries =
        AgentRPC::KernelServices::LanePromptBuffer.list(draft: draft, buffer_name: "summaries").fetch("entries")
      assert_equal [persisted.id, entry.fetch("id")], listed_entries.map { |listed| listed.fetch("id") }
      assert_equal ["Persisted summary", "Fresh summary"], listed_entries.map { |listed| listed.fetch("content") }

      fetched =
        AgentRPC::KernelServices::LanePromptBuffer.get(draft: draft, entry_id: entry.fetch("id")).fetch("entry")
      assert_equal entry, fetched

      snapshot = AgentRPC::KernelServices::LanePromptBuffer.snapshot(draft: draft)
      assert_equal [persisted.id, entry.fetch("id")], snapshot.fetch("entries").map { |listed| listed.fetch("id") }

      AgentRPC::KernelServices::LanePromptBuffer.delete!(draft: draft, entry_id: entry.fetch("id"))
      assert_equal [persisted.id], AgentRPC::KernelServices::LanePromptBuffer.list(draft: draft, buffer_name: "summaries").fetch("entries").map { |listed| listed.fetch("id") }

      AgentRPC::KernelServices::LanePromptBuffer.clear!(draft: draft, buffer_name: "summaries")
      assert_equal [], AgentRPC::KernelServices::LanePromptBuffer.list(draft: draft, buffer_name: "summaries").fetch("entries")
    end
  end

  test "render selects by priority and newness but returns selected entries in sequence order" do
    draft = create_prepared_draft!
    lane = draft.bound_lane

    low =
      LanePromptBufferEntry.create!(
        lane: lane,
        buffer_name: "working_notes",
        seq: 10,
        kind: "note",
        content: "Low priority note",
        priority: 1,
        estimated_tokens: 3,
      )
    high_older =
      LanePromptBufferEntry.create!(
        lane: lane,
        buffer_name: "working_notes",
        seq: 20,
        kind: "note",
        content: "High priority older note",
        priority: 5,
        estimated_tokens: 4,
      )
    high_newer =
      LanePromptBufferEntry.create!(
        lane: lane,
        buffer_name: "working_notes",
        seq: 30,
        kind: "note",
        content: "High priority newer note",
        priority: 5,
        estimated_tokens: 4,
      )
    oversized =
      LanePromptBufferEntry.create!(
        lane: lane,
        buffer_name: "working_notes",
        seq: 40,
        kind: "note",
        content: "Oversized note",
        priority: 9,
        estimated_tokens: 20,
      )

    rendered =
      AgentRPC::KernelServices::LanePromptBuffer.render(
        draft: draft,
        buffer_name: "working_notes",
        max_tokens: 8,
      )

    assert_equal [high_older.id, high_newer.id], rendered.fetch("entry_ids")
    assert_equal [high_older.id, high_newer.id], rendered.fetch("entries").map { |entry| entry.fetch("id") }
    assert_equal "High priority older note\n\nHigh priority newer note", rendered.fetch("content")
    assert_equal 8, rendered.fetch("estimated_tokens")
    assert_equal true, rendered.fetch("truncated")
    assert_equal 2, rendered.fetch("remaining_entries_count")
    assert_equal [oversized.id], rendered.fetch("oversized_entry_ids")
    assert_equal [low.id, oversized.id].sort, (rendered.fetch("remaining_entry_ids") - rendered.fetch("entry_ids")).sort
  end

  private

    def create_prepared_draft!
      conversation = create_conversation!
      program = conversation.agent_program
      deployment = program.active_healthy_deployment_for_published_contract
      credential = LLMProviderCredential.find_by!(provider_key: "dev")
      target = conversation.default_execution_target

      RunDraft.create!(
        conversation: conversation,
        initiated_by_user: conversation.user,
        status: "prepared",
        permission_mode: "default",
        trigger_snapshot: { "kind" => "user_turn", "dag_node_id" => SecureRandom.uuid },
        agent_program: program,
        contract_fingerprint: program.published_contract_fingerprint,
        agent_deployment: deployment,
        deployment_fingerprint: deployment.deployment_fingerprint,
        deployment_activated_at: deployment.activated_at&.change(usec: 0),
        provider_credential: credential,
        proposed_execution_target: target,
        selected_model_ref: "dev/mock-model",
        runtime_governors: runtime_governors_snapshot(provider_credential: credential, selected_model_ref: "dev/mock-model", execution_target: target),
        agent_config_schema_fingerprint: conversation.agent_config_schema_fingerprint,
        prepare_invocation_id: SecureRandom.uuid,
        planning: {},
        staged_public_settings_patch: {},
        staged_agent_config_patch: {},
        staged_kv_ops: [],
        staged_prompt_buffer_ops: [],
        approval_state: { "status" => "not_required" },
        expires_at: 30.minutes.from_now.change(usec: 0),
      )
    end

    def with_token_counter(counter)
      singleton = Cybros::AgentRuntimeResolver.singleton_class
      singleton.alias_method :__lane_prompt_buffer_test_original_token_counter_for_model_ref, :token_counter_for_model_ref
      singleton.define_method(:token_counter_for_model_ref) do |model_ref:|
        _ = model_ref
        counter
      end

      yield
    ensure
      if singleton.method_defined?(:__lane_prompt_buffer_test_original_token_counter_for_model_ref)
        singleton.alias_method :token_counter_for_model_ref, :__lane_prompt_buffer_test_original_token_counter_for_model_ref
        singleton.remove_method :__lane_prompt_buffer_test_original_token_counter_for_model_ref
      end
    end
end
