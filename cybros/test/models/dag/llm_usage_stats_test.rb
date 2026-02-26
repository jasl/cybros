require "test_helper"

class DAG::LlmUsageStatsTest < ActiveSupport::TestCase
  test "lane.llm_usage_stats returns empty totals when there are no usage nodes" do
    conversation = create_conversation!
    lane = conversation.dag_graph.main_lane

    stats = lane.llm_usage_stats

    totals = stats.fetch("totals")
    assert_equal 0, totals.fetch("calls")
    assert_equal 0, totals.fetch("input_tokens")
    assert_equal 0, totals.fetch("output_tokens")
    assert_equal 0, totals.fetch("cache_creation_tokens")
    assert_equal 0, totals.fetch("cache_read_tokens")
    assert_equal 0, totals.fetch("cache_miss_tokens")
    assert_equal 0, totals.fetch("total_tokens")
    assert totals.key?("cache_hit_rate")
    assert_nil totals.fetch("cache_hit_rate")

    assert_equal [], stats.fetch("by_model")
    assert_equal [], stats.fetch("by_day")
  end

  test "lane.llm_usage_stats aggregates usage and cache hit rate" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    day_1 = Time.zone.local(2026, 2, 23, 10, 0, 0)
    day_2 = Time.zone.local(2026, 2, 24, 11, 0, 0)

    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: "0194f3c0-0000-7000-8000-00000000b101",
      metadata: {
        "usage" => { "input_tokens" => 100, "output_tokens" => 50, "cache_read_tokens" => 40 },
      },
      body_output: { "provider" => "simple_inference", "model" => "gpt-5.2", "content" => "a1" },
      created_at: day_1,
      finished_at: day_1,
      updated_at: day_1,
    )

    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: "0194f3c0-0000-7000-8000-00000000b102",
      metadata: {
        "usage" => { "input_tokens" => 10, "output_tokens" => 5, "cache_read_tokens" => 0 },
      },
      body_output: { "provider" => "simple_inference", "model" => "gpt-5.2", "content" => "a2" },
      created_at: day_2,
      finished_at: day_2,
      updated_at: day_2,
    )

    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: "0194f3c0-0000-7000-8000-00000000b103",
      metadata: {
        "usage" => { "input_tokens" => 20, "output_tokens" => 10, "cache_read_tokens" => 20 },
      },
      body_output: { "provider" => "simple_inference", "model" => "deepseek-v3", "content" => "a3" },
      created_at: day_2 + 1.second,
      finished_at: day_2 + 1.second,
      updated_at: day_2 + 1.second,
    )

    stats = lane.llm_usage_stats

    totals = stats.fetch("totals")
    assert_equal 3, totals.fetch("calls")
    assert_equal 130, totals.fetch("input_tokens")
    assert_equal 65, totals.fetch("output_tokens")
    assert_equal 60, totals.fetch("cache_read_tokens")
    assert_equal 195, totals.fetch("total_tokens")

    assert_in_delta 60.0 / 130.0, totals.fetch("cache_hit_rate"), 1e-9

    by_model = stats.fetch("by_model")
    assert_equal 2, by_model.length

    gpt = by_model.first
    assert_equal "simple_inference", gpt.fetch("provider")
    assert_equal "gpt-5.2", gpt.fetch("model")
    assert_equal 2, gpt.fetch("calls")
    assert_equal 110, gpt.fetch("input_tokens")
    assert_equal 55, gpt.fetch("output_tokens")
    assert_equal 40, gpt.fetch("cache_read_tokens")
    assert_in_delta 40.0 / 110.0, gpt.fetch("cache_hit_rate"), 1e-9

    deepseek = by_model.second
    assert_equal "deepseek-v3", deepseek.fetch("model")
    assert_in_delta 1.0, deepseek.fetch("cache_hit_rate"), 1e-9

    by_day = stats.fetch("by_day")
    assert_equal ["2026-02-23", "2026-02-24"], by_day.map { |row| row.fetch("date") }

    day2 = by_day.last
    assert_equal 2, day2.fetch("calls")
    assert_equal 30, day2.fetch("input_tokens")
    assert_equal 15, day2.fetch("output_tokens")
    assert_equal 20, day2.fetch("cache_read_tokens")
  end

  test "lane.llm_usage_stats tolerates invalid usage values without raising" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    lane = graph.main_lane

    t1 = Time.zone.local(2026, 2, 24, 11, 0, 0)

    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: "0194f3c0-0000-7000-8000-00000000b111",
      metadata: { "usage" => { "input_tokens" => 10, "output_tokens" => 2, "cache_read_tokens" => 7 } },
      body_output: { "provider" => "simple_inference", "model" => "gpt-5.2", "content" => "ok" },
      created_at: t1,
      finished_at: t1,
      updated_at: t1,
    )

    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: lane.id,
      turn_id: "0194f3c0-0000-7000-8000-00000000b112",
      metadata: { "usage" => { "input_tokens" => "nope", "output_tokens" => "x", "cache_read_tokens" => "??" } },
      body_output: { "provider" => "simple_inference", "model" => "gpt-5.2", "content" => "bad" },
      created_at: t1 + 1.second,
      finished_at: t1 + 1.second,
      updated_at: t1 + 1.second,
    )

    stats = lane.llm_usage_stats

    totals = stats.fetch("totals")
    assert_equal 2, totals.fetch("calls")
    assert_equal 10, totals.fetch("input_tokens")
    assert_equal 2, totals.fetch("output_tokens")
    assert_equal 7, totals.fetch("cache_read_tokens")
    assert_in_delta 0.7, totals.fetch("cache_hit_rate"), 1e-9
  end

  test "graph.llm_usage_stats can aggregate across lanes and filter by time range" do
    conversation = create_conversation!
    graph = conversation.dag_graph
    main_lane = graph.main_lane
    branch_lane = graph.lanes.create!(role: DAG::Lane::BRANCH, parent_lane_id: main_lane.id, metadata: {})

    t1 = Time.zone.local(2026, 2, 23, 10, 0, 0)
    t2 = Time.zone.local(2026, 2, 24, 11, 0, 0)

    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: main_lane.id,
      turn_id: "0194f3c0-0000-7000-8000-00000000b201",
      metadata: { "usage" => { "input_tokens" => 10, "output_tokens" => 1, "cache_read_tokens" => 0 } },
      body_output: { "provider" => "simple_inference", "model" => "gpt-5.2", "content" => "main" },
      created_at: t1,
      finished_at: t1,
      updated_at: t1,
    )

    graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      lane_id: branch_lane.id,
      turn_id: "0194f3c0-0000-7000-8000-00000000b202",
      metadata: { "usage" => { "input_tokens" => 20, "output_tokens" => 2, "cache_read_tokens" => 10 } },
      body_output: { "provider" => "simple_inference", "model" => "deepseek-v3", "content" => "branch" },
      created_at: t2,
      finished_at: t2,
      updated_at: t2,
    )

    all = graph.llm_usage_stats
    assert_equal 2, all.dig("totals", "calls")
    assert_equal 30, all.dig("totals", "input_tokens")

    filtered = graph.llm_usage_stats(since: t2, until_time: t2)
    assert_equal 1, filtered.dig("totals", "calls")
    assert_equal 20, filtered.dig("totals", "input_tokens")
    assert_equal ["2026-02-24"], filtered.fetch("by_day").map { |row| row.fetch("date") }
  end

  test "graph.llm_usage_stats validates lane_id and time params" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    error =
      assert_raises(DAG::ValidationError) do
        graph.llm_usage_stats(lane_id: "not-a-uuid")
      end
    assert_equal "dag.usage_stats.lane_id_must_be_a_uuid", error.code

    error =
      assert_raises(DAG::ValidationError) do
        graph.llm_usage_stats(since: "nope")
      end
    assert_equal "dag.usage_stats.since_must_be_a_time", error.code
  end

  test "llm_usage_stats validates until_time is >= since" do
    conversation = create_conversation!
    graph = conversation.dag_graph

    error =
      assert_raises(DAG::ValidationError) do
        graph.llm_usage_stats(since: "2026-02-24", until_time: "2026-02-23")
      end
    assert_equal "dag.usage_stats.until_time_must_be_gte_since", error.code
  end
end
