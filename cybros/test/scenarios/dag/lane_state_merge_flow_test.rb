require "test_helper"

class DAG::LaneStateMergeFlowTest < ActiveSupport::TestCase
  test "merge_lane_state applies frozen snapshots to the target lane" do
    root = create_conversation!(title: "Root")
    graph = root.root_graph
    main_lane = root.chat_lane

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
        )
    end

    main_lane.lane_kv_entries.create!(
      key: "shared.stage",
      value: { "status" => "main" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )
    main_lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 10,
      kind: "note",
      content: "Parent handoff",
      priority: 10,
      estimated_tokens: 7,
    )

    branch = root.create_child!(from_node_id: agent.id, kind: "branch", title: "Branch", user_content: "What if?")
    branch_lane = branch.chat_lane
    branch_lane.lane_kv_entries.find_by!(key: "shared.stage").update!(value: { "status" => "branch" })
    branch_lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 20,
      kind: "note",
      content: "Branch handoff",
      priority: 50,
      estimated_tokens: 7,
    )

    root.append_user_message!(content: "Main followup")
    main_agent = graph.leaf_nodes.where(lane_id: main_lane.id).order(:id).last
    main_agent.mark_running!
    main_agent.mark_finished!(content: "Main done")

    branch.append_user_message!(content: "Branch followup")
    branch_agent = graph.leaf_nodes.where(lane_id: branch_lane.id).order(:id).last
    branch_agent.mark_running!
    branch_agent.mark_finished!(content: "Branch done")

    merge_task = branch.merge_into_parent!(metadata: { "reason" => "test" })

    branch_lane.lane_kv_entries.find_by!(key: "shared.stage").update!(value: { "status" => "mutated_after_merge_request" })
    LanePromptBufferEntry.create!(
      lane: branch_lane,
      buffer_name: "handoff",
      seq: 30,
      kind: "note",
      content: "Late branch note",
      priority: 5,
      estimated_tokens: 5,
    )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Struct.new(:name).new("test-provider"),
        model: "dev/mock-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new.tap { |registry| registry.register_many(Cybros::LaneState::Tools.build) },
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: {},
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)
    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [merge_task.id], claimed.map(&:id)
      DAG::Runner.run_node!(merge_task.id)

      merge_task.reload
      assert_equal DAG::Node::FINISHED, merge_task.state
      assert_equal({ "status" => "branch" }, main_lane.lane_kv_entries.find_by!(key: "shared.stage").value)
      assert_equal ["Parent handoff", "Branch handoff"], main_lane.lane_prompt_buffer_entries.where(buffer_name: "handoff").ordered.pluck(:content)
      assert branch_lane.reload.archived_at.blank?

      result = AgentCore::Resources::Tools::ToolResult.from_h(merge_task.body_output.fetch("result"))
      refute result.error?
      assert_includes result.text, "Merged lane state"
      assert_equal "branch", result.metadata.fetch("target_lane_kv_patch").sole.fetch("value").fetch("status")
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end

  test "merge_lane_state merges multiple source lane snapshots in order" do
    root = create_conversation!(title: "Root")
    graph = root.root_graph
    main_lane = root.chat_lane

    agent = nil
    graph.mutate! do |m|
      agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          metadata: {},
        )
    end

    main_lane.lane_kv_entries.create!(
      key: "shared.stage",
      value: { "status" => "main" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )
    main_lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 10,
      kind: "note",
      content: "Parent handoff",
      priority: 10,
      estimated_tokens: 7,
    )

    branch_a = root.create_child!(from_node_id: agent.id, kind: "branch", title: "Branch A", user_content: "What if A?")
    branch_b = root.create_child!(from_node_id: agent.id, kind: "branch", title: "Branch B", user_content: "What if B?")
    branch_a_lane = branch_a.chat_lane
    branch_b_lane = branch_b.chat_lane
    branch_a_seed_agent = graph.nodes.active.where(lane_id: branch_a_lane.id, node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).sole
    branch_b_seed_agent = graph.nodes.active.where(lane_id: branch_b_lane.id, node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING).sole
    branch_a_seed_agent.mark_running!
    branch_a_seed_agent.mark_finished!(content: "Branch A seed done")
    branch_b_seed_agent.mark_running!
    branch_b_seed_agent.mark_finished!(content: "Branch B seed done")

    branch_a_lane.lane_kv_entries.find_by!(key: "shared.stage").update!(value: { "status" => "branch_a" })
    branch_a_lane.lane_kv_entries.create!(
      key: "branch_a.only",
      value: { "status" => "branch_a_only" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )
    branch_a_lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 20,
      kind: "note",
      content: "Shared handoff",
      priority: 30,
      estimated_tokens: 6,
    )

    branch_b_lane.lane_kv_entries.find_by!(key: "shared.stage").update!(value: { "status" => "branch_b" })
    branch_b_lane.lane_kv_entries.create!(
      key: "branch_b.only",
      value: { "status" => "branch_b_only" },
      written_by_type: "Seed",
      written_by_id: SecureRandom.uuid,
    )
    branch_b_lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 20,
      kind: "note",
      content: "Shared handoff",
      priority: 40,
      estimated_tokens: 6,
    )
    branch_b_lane.lane_prompt_buffer_entries.create!(
      buffer_name: "handoff",
      seq: 30,
      kind: "note",
      content: "Branch B handoff",
      priority: 50,
      estimated_tokens: 7,
    )

    target_snapshot = root.send(:lane_state_snapshot, lane: main_lane)
    branch_a_snapshot = root.send(:lane_state_snapshot, lane: branch_a_lane)
    branch_b_snapshot = root.send(:lane_state_snapshot, lane: branch_b_lane)

    branch_a_lane.lane_kv_entries.find_by!(key: "shared.stage").update!(value: { "status" => "mutated_after_merge_request_a" })
    branch_b_lane.lane_kv_entries.find_by!(key: "shared.stage").update!(value: { "status" => "mutated_after_merge_request_b" })
    LanePromptBufferEntry.create!(
      lane: branch_a_lane,
      buffer_name: "handoff",
      seq: 40,
      kind: "note",
      content: "Late branch A note",
      priority: 5,
      estimated_tokens: 5,
    )
    LanePromptBufferEntry.create!(
      lane: branch_b_lane,
      buffer_name: "handoff",
      seq: 40,
      kind: "note",
      content: "Late branch B note",
      priority: 5,
      estimated_tokens: 5,
    )

    merge_task =
      graph.nodes.create!(
        node_type: Messages::Task.node_type_key,
        state: DAG::Node::PENDING,
        lane_id: main_lane.id,
        turn_id: SecureRandom.uuid,
        metadata: {},
        body_input: {
          "tool_call_id" => "merge_lane_state:#{branch_a_lane.id},#{branch_b_lane.id}",
          "requested_name" => "merge_lane_state",
          "name" => "merge_lane_state",
          "arguments" => {
            "target_lane_id" => main_lane.id,
            "source_lane_ids" => [branch_a_lane.id, branch_b_lane.id],
            "target_lane_kv_snapshot" => target_snapshot.fetch("kv_entries"),
            "source_lane_kv_snapshots" => [
              { "lane_id" => branch_a_lane.id, "entries" => branch_a_snapshot.fetch("kv_entries") },
              { "lane_id" => branch_b_lane.id, "entries" => branch_b_snapshot.fetch("kv_entries") },
            ],
            "target_prompt_buffer_snapshot" => target_snapshot.fetch("prompt_buffer_entries"),
            "source_prompt_buffer_snapshots" => [
              { "lane_id" => branch_a_lane.id, "entries" => branch_a_snapshot.fetch("prompt_buffer_entries") },
              { "lane_id" => branch_b_lane.id, "entries" => branch_b_snapshot.fetch("prompt_buffer_entries") },
            ],
            "merge_metadata" => { "reason" => "multi_source" },
            "archive_source_lanes" => false,
          },
          "arguments_summary" => "{}",
          "source" => "test",
        },
      )

    runtime =
      AgentCore::DAG::Runtime.new(
        provider: Struct.new(:name).new("test-provider"),
        model: "dev/mock-model",
        tools_registry: AgentCore::Resources::Tools::Registry.new.tap { |registry| registry.register_many(Cybros::LaneState::Tools.build) },
        tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
        llm_options: {},
        instrumenter: AgentCore::Observability::NullInstrumenter.new,
      )

    original_runtime_resolver = AgentCore::DAG.runtime_resolver
    original_registry = DAG.executor_registry

    DAG.executor_registry = DAG::ExecutorRegistry.new
    DAG.executor_registry.register(Messages::Task.node_type_key, AgentCore::DAG::Executors::TaskExecutor.new)
    AgentCore::DAG.runtime_resolver = ->(node:) { _ = node; runtime }

    begin
      claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
      assert_equal [merge_task.id], claimed.map(&:id)
      DAG::Runner.run_node!(merge_task.id)

      merge_task.reload
      assert_equal DAG::Node::FINISHED, merge_task.state
      assert_equal({ "status" => "branch_b" }, main_lane.lane_kv_entries.find_by!(key: "shared.stage").value)
      assert_equal({ "status" => "branch_a_only" }, main_lane.lane_kv_entries.find_by!(key: "branch_a.only").value)
      assert_equal({ "status" => "branch_b_only" }, main_lane.lane_kv_entries.find_by!(key: "branch_b.only").value)

      handoff_entries = main_lane.lane_prompt_buffer_entries.where(buffer_name: "handoff").ordered.pluck(:content)
      assert_equal ["Parent handoff", "Shared handoff", "Branch B handoff"], handoff_entries
      refute_includes handoff_entries, "Late branch A note"
      refute_includes handoff_entries, "Late branch B note"

      result = AgentCore::Resources::Tools::ToolResult.from_h(merge_task.body_output.fetch("result"))
      refute result.error?
      conflicts = result.metadata.fetch("conflicts")
      assert conflicts.any? { |entry| entry.fetch("key") == "shared.stage" && entry.fetch("source_lane_id") == branch_a_lane.id }
      assert conflicts.any? { |entry| entry.fetch("key") == "shared.stage" && entry.fetch("source_lane_id") == branch_b_lane.id }
      assert_equal [branch_a_lane.id, branch_b_lane.id], result.metadata.fetch("source_lane_ids")
    ensure
      AgentCore::DAG.runtime_resolver = original_runtime_resolver
      DAG.executor_registry = original_registry
    end
  end
end
