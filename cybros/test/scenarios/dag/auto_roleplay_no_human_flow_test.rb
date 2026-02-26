require "test_helper"

class DAG::AutoRoleplayNoHumanFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class AutoCharacterExecutor
    def execute(node:, context:, stream:)
      _ = context
      _ = stream

      actor = node.metadata["actor"].to_s
      step = Integer(node.metadata["step"] || 0)
      max_steps = Integer(node.metadata["max_steps"] || 0)

      if step < max_steps
        next_actor = actor == "alice" ? "bob" : "alice"

        node.graph.mutate! do |m|
          next_node =
            m.create_node(
              node_type: Messages::CharacterMessage.node_type_key,
              state: DAG::Node::PENDING,
              metadata: {
                "actor" => next_actor,
                "step" => step + 1,
                "max_steps" => max_steps,
              }
            )

          m.create_edge(from_node: node, to_node: next_node, edge_type: DAG::Edge::SEQUENCE, metadata: { "generated_by" => "auto" })
        end
      end

      content = "#{actor}: step=#{step}"
      DAG::ExecutionResult.finished(payload: { "content" => content }, usage: { "total_tokens" => 1 })
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "auto without human: alternating character messages across multiple turns with transcript pagination" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    turn_id = "0194f3c0-0000-7000-8000-00000000d100"
    user = nil
    first = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Begin", metadata: {})
      first =
        m.create_node(
          node_type: Messages::CharacterMessage.node_type_key,
          state: DAG::Node::PENDING,
          metadata: {
            "actor" => "alice",
            "step" => 1,
            "max_steps" => 4,
          }
        )
      m.create_edge(from_node: user, to_node: first, edge_type: DAG::Edge::SEQUENCE)
    end

    registry = DAG::ExecutorRegistry.new
    registry.register(Messages::CharacterMessage.node_type_key, AutoCharacterExecutor.new)

    original_registry = DAG.executor_registry
    DAG.executor_registry = registry

    begin
      10.times do
        claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 10, claimed_by: "test")
        break if claimed.empty?

        claimed.each { |n| DAG::Runner.run_node!(n.id) }
      end

      characters = graph.nodes.active.where(node_type: Messages::CharacterMessage.node_type_key).order(:id).to_a
      assert_equal 4, characters.length
      assert characters.all?(&:finished?)

      assert_equal 4, lane.anchored_turn_count(include_deleted: true)

      page = lane.transcript_page(limit_turns: 2)
      assert_equal 2, page.fetch("turn_ids").length

      older = lane.transcript_page(limit_turns: 2, before_turn_id: page.fetch("before_turn_id"))
      assert_equal 2, older.fetch("turn_ids").length

      all_turn_ids = (older.fetch("turn_ids") + page.fetch("turn_ids"))
      assert_equal all_turn_ids.uniq, all_turn_ids

      transcript = (older.fetch("transcript") + page.fetch("transcript"))
      transcript_contents =
        transcript.map do |n|
          if n.fetch("node_type") == Messages::UserMessage.node_type_key
            n.dig("payload", "input", "content").to_s
          else
            n.dig("payload", "output_preview", "content").to_s
          end
        end

      assert_includes transcript_contents.join("\n"), "Begin"
      assert_includes transcript_contents.join("\n"), "alice: step=1"
      assert_includes transcript_contents.join("\n"), "bob: step=2"
      assert_includes transcript_contents.join("\n"), "alice: step=3"
      assert_includes transcript_contents.join("\n"), "bob: step=4"

      assert_equal [], DAG::GraphAudit.scan(graph: graph)
    ensure
      DAG.executor_registry = original_registry
    end
  end
end
