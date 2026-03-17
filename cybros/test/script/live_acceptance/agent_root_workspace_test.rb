require "test_helper"
require "net/http"
require "stringio"
require "tmpdir"
require_relative "../../support/programmable_agent_runtime_test_support"

ENV["CYBROS_LIVE_ACCEPTANCE_NO_AUTORUN"] = "1"
require Rails.root.join("script/live_acceptance/agent_root_workspace")

class AgentRootWorkspaceLiveAcceptanceTest < ActiveSupport::TestCase
  include ProgrammableAgentRuntimeTestSupport

  test "harness enumerates the required seventeen live scenarios and requires three consecutive passes each" do
    scenario_ids = Cybros::LiveAcceptance::AgentRootWorkspace::Runner::SCENARIOS.map(&:id)

    assert_equal 17, scenario_ids.length
    assert_equal 17, scenario_ids.uniq.length
    assert_equal [
      "root_shared_memory",
      "conversation_isolation",
      "lane_local_memory_isolation",
      "branch_snapshot_inheritance",
      "directory_complexity_tolerance",
      "compaction_durability",
      "self_mutate_soul",
      "self_mutate_user",
      "create_agent_local_skill",
      "modify_agent_local_skill",
      "deny_agents_mutation",
      "catalog_skill_install",
      "github_skill_install",
      "repo_root_skill_batch_install",
      "replace_installed_skill",
      "deny_platform_skill_collision_install",
      "deny_exec_skill_mutation",
    ], scenario_ids
    assert_equal 3, Cybros::LiveAcceptance::AgentRootWorkspace::Runner::RUNS_PER_SCENARIO
  end

  test "protected-write scenarios stay approval-driven through the shipped approval path" do
    protected_scenarios =
      Cybros::LiveAcceptance::AgentRootWorkspace::Runner::SCENARIOS.select(&:requires_approval?).map(&:id)

    assert_equal(
      %w[
        self_mutate_soul
        self_mutate_user
        create_agent_local_skill
        modify_agent_local_skill
        catalog_skill_install
        github_skill_install
        repo_root_skill_batch_install
        replace_installed_skill
      ],
      protected_scenarios,
    )
    assert_equal(
      :approve_awaiting_nodes,
      Cybros::LiveAcceptance::AgentRootWorkspace::Runner::APPROVAL_DRIVER
    )
  end

  test "proof markdown captures the report metadata and scenario outcome table" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    markdown =
      runner.proof_markdown(
        started_at: Time.utc(2026, 3, 16, 9, 0, 0),
        finished_at: Time.utc(2026, 3, 16, 10, 0, 0),
        model_ref: "openrouter/openai-gpt-5.4",
        environment_label: "development",
        results: [],
      )

    assert_includes markdown, "# Agent Root Workspace Proof"
    assert_includes markdown, "Started at (UTC)"
    assert_includes markdown, "Finished at (UTC)"
    assert_includes markdown, "Model ref"
    assert_includes markdown, "Environment"
    assert_includes markdown, "Scenario outcomes"
    assert_includes markdown, "Source hash"
    assert_includes markdown, "Installed hash"
    assert_includes markdown, "Snapshot path"
    assert_includes markdown, "DAG"
    assert_includes markdown, "Mermaid"
  end

  test "installed_skill_entry_for! selects batch entries by installed name and defaults to the first entry" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    payload = {
      "installed_skills" => [
        {
          "installed_name" => "alpha-skill",
          "source_sha256" => "sha-alpha",
          "installed_sha256" => "sha-alpha",
          "snapshot_path" => "",
        },
        {
          "installed_name" => "system-helper",
          "source_sha256" => "sha-system",
          "installed_sha256" => "sha-system",
          "snapshot_path" => "/tmp/snapshot",
        },
      ],
    }

    assert_equal "alpha-skill", runner.send(:installed_skill_entry_for!, payload).fetch("installed_name")
    assert_equal "system-helper", runner.send(:installed_skill_entry_for!, payload, installed_name: "system-helper").fetch("installed_name")

    error =
      assert_raises(Cybros::LiveAcceptance::AgentRootWorkspace::ScenarioFailure) do
        runner.send(:installed_skill_entry_for!, payload, installed_name: "missing-skill")
      end
    assert_match(/missing-skill/, error.message)
  end

  test "with_callback_base_url serves the local app and restores CYBROS_BASE_URL" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    previous = ENV["CYBROS_BASE_URL"]
    ENV.delete("CYBROS_BASE_URL")
    yielded_base_url = nil

    runner.send(:with_callback_base_url) do |base_url|
      yielded_base_url = base_url
      assert_equal base_url, ENV["CYBROS_BASE_URL"]

      response = Net::HTTP.get_response(URI("#{base_url}/up"))
      assert response.is_a?(Net::HTTPSuccess), response.inspect
    end

    assert yielded_base_url.present?
    assert_nil ENV["CYBROS_BASE_URL"]
  ensure
    if previous.nil?
      ENV.delete("CYBROS_BASE_URL")
    else
      ENV["CYBROS_BASE_URL"] = previous
    end
  end

  test "export_conversation_dag_artifacts! validates DAG structure and writes mermaid artifacts" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(
      io: StringIO.new,
      report_path: Rails.root.join("tmp/live-acceptance-proof.md"),
    )
    conversation = create_conversation!(title: "Mermaid proof")
    graph = conversation.dag_graph

    user = graph.nodes.create!(
      node_type: Messages::UserMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_input: { "content" => "Hello" },
      metadata: {},
    )
    agent = graph.nodes.create!(
      node_type: Messages::AgentMessage.node_type_key,
      state: DAG::Node::FINISHED,
      body_output: { "content" => "World" },
      metadata: {},
    )
    graph.edges.create!(from_node_id: user.id, to_node_id: agent.id, edge_type: DAG::Edge::SEQUENCE)

    artifacts =
      runner.send(
        :export_conversation_dag_artifacts!,
        scenario_id: "probe",
        run_index: 1,
        conversation_ids: [conversation.id],
      )

    assert_equal 1, artifacts.length
    artifact = artifacts.first
    assert_equal conversation.id.to_s, artifact.fetch(:conversation_id)
    assert_equal 1, artifact.fetch(:root_count)
    assert_equal 1, artifact.fetch(:component_count)

    mermaid_path = Rails.root.join("tmp", artifact.fetch(:mermaid_path))
    assert_predicate mermaid_path, :file?
    assert_includes mermaid_path.read, "flowchart TD"
  ensure
    FileUtils.rm_rf(Rails.root.join("tmp/live-acceptance-proof-artifacts"))
  end

  test "run_series_for can invoke private scenario handlers when the standalone harness executes" do
    runner_class =
      Class.new(Cybros::LiveAcceptance::AgentRootWorkspace::Runner) do
        private

          def reset_agent_root!(_agent)
          end

          def export_conversation_dag_artifacts!(**)
            []
          end

          def run_probe!(agent:, model_ref:, run_index:)
            {
              approval_count: 0,
              conversation_ids: ["conversation-#{run_index}"],
              note: "#{agent}:#{model_ref}:#{run_index}",
            }
          end
      end
    runner = runner_class.new(io: StringIO.new, runs_per_scenario: 1)
    scenario = Cybros::LiveAcceptance::AgentRootWorkspace::Scenario.new(id: "probe", label: "Probe", requires_approval: false)

    result = runner.send(:run_series_for, scenario, agent: "agent-ref", model_ref: "model-ref")

    assert result.fetch(:success)
    assert_equal 1, result.fetch(:runs).length
    assert_equal "agent-ref:model-ref:1", result.fetch(:runs).first.fetch(:note)
  end

  test "compaction_durability uses a live-acceptance alias when one exists for the requested model" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)

    assert_equal(
      "openrouter/openai-gpt-5.4-live-acceptance",
      runner.send(:scenario_model_ref_for, scenario_id: "compaction_durability", model_ref: "openrouter/openai-gpt-5.4"),
    )
    assert_equal(
      "openrouter/openai-gpt-5.4",
      runner.send(:scenario_model_ref_for, scenario_id: "root_shared_memory", model_ref: "openrouter/openai-gpt-5.4"),
    )
    assert_equal(
      "dev/mock-model",
      runner.send(:scenario_model_ref_for, scenario_id: "compaction_durability", model_ref: "dev/mock-model"),
    )
  end

  test "submit_turn! drives approval-gated protected writes through the shipped approval path before returning" do
    token = "HARNESS_APPROVAL_TOKEN_#{SecureRandom.hex(4)}"
    llm_responses = [
      MockLLMServer.chat_response(
        content: "Need protected write",
        finish_reason: "tool_calls",
        tool_calls: [
          {
            "id" => "tc_write_soul",
            "type" => "function",
            "function" => {
              "name" => "write",
              "arguments" => JSON.generate(
                {
                  "path" => "../../SOUL.md",
                  "content" => "- Explain intended work clearly before acting.\n#{token}\n",
                },
              ),
            },
          },
        ],
      ),
      MockLLMServer.chat_response(content: "Protected write finished."),
    ]
    llm_server = MockLLMServer.new { |_payload| llm_responses.shift || MockLLMServer.chat_response(content: "Unexpected extra turn.") }.start
    server = Cybros::ProgrammableAgentFixture::Server.new(required_bearer: "secret://fixture").start

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        with_default_agent_workspace_root(workspace_root) do
          runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
          program = create_program!
          deployment = create_active_deployment!(program: program, endpoint_url: server.rpc_url)
          Cybros::ProgrammableAgent::CapabilityHandshake.handshake!(deployment: deployment)
          deployment.reload

          conversation = create_programmable_conversation!(program: program, llm_options: { "stream" => false })
          conversation.update!(
            permission_mode: "full_access",
            agent_config_schema_fingerprint: conversation.agent.config_schema_fingerprint,
          )
          Conversations::WorkspaceInitializer.initialize!(conversation: conversation)

          turn = runner.send(:submit_turn!, conversation: conversation, content: "Append a protected token.", model_ref: "dev/mock-model")

          assert_equal 1, turn.fetch(:approval_count)

          active_turn_nodes =
            conversation.root_graph.nodes.active.where(turn_id: turn.fetch(:agent_node).turn_id).order(:id).to_a
          protected_write_task =
            active_turn_nodes.find do |node|
              node.node_type == Messages::Task.node_type_key && node.body_input["name"] == "write"
            end
          final_agent_message =
            active_turn_nodes.select { |node| node.node_type == Messages::AgentMessage.node_type_key }.max_by(&:id)

          assert protected_write_task.present?,
            active_turn_nodes.map { |node| { id: node.id, type: node.node_type, state: node.state, input: node.body_input, metadata: node.metadata } }
          assert_equal "live-acceptance:harness", protected_write_task.metadata["approved_by"]
          assert_equal DAG::Node::FINISHED, protected_write_task.state
          assert_equal "Protected write finished.", final_agent_message.body_output.fetch("content")
          assert active_turn_nodes.all?(&:terminal?), active_turn_nodes.map { |node| { id: node.id, type: node.node_type, state: node.state } }
          assert_empty active_turn_nodes.select(&:awaiting_approval?)
        end
      end
    end
  ensure
    server&.shutdown
    llm_server&.shutdown
  end

  test "deny_agents_mutation accepts a direct refusal when AGENTS.md stays unchanged" do
    llm_server =
      MockLLMServer.new do |_payload|
        MockLLMServer.chat_response(content: "I can't modify AGENTS.md because it is read-only in this workspace.")
      end.start

    with_catalog_yaml(mock_llm_catalog_yaml(base_url: llm_server.base_url)) do
      Dir.mktmpdir("cybros-agent-root-") do |workspace_root|
        with_default_agent_workspace_root(workspace_root) do
          runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
          agent = Agents::BootstrapBundledDefaultService.ensure_agent!

          result = runner.send(:run_deny_agents_mutation!, agent: agent, model_ref: "dev/mock-model", run_index: 1)

          assert_equal 0, result.fetch(:approval_count)
          assert_equal "AGENTS.md stayed read-only", result.fetch(:note)
          assert_equal 1, result.fetch(:conversation_ids).length
        end
      end
    end
  ensure
    llm_server&.shutdown
  end

  test "agents_mutation_denied? accepts policy-denied task results when the protected path only appears in task arguments" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    task =
      Struct.new(:body_input, :body_output).new(
        {
          "name" => "edit",
          "arguments" => {
            "path" => "../../AGENTS.md",
            "old_text" => "before",
            "new_text" => "after",
          },
        },
        {
          "result" =>
            AgentCore::Resources::Tools::ToolResult.error(
              text: "Tool 'edit' denied by policy (reason=protected_agent_root_read_only).",
            ).to_h,
        },
      )

    assert(
      runner.send(
        :agents_mutation_denied?,
        task: task,
        final_content: "I attempted it, but the write was denied by policy and I did not modify any file.",
      ),
    )
  end

  test "final_agent_node_for_turn! returns the post-tool-loop agent message" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    conversation = create_conversation!(metadata: { "agent" => {} })
    graph = conversation.root_graph
    turn_id = SecureRandom.uuid
    final_agent = nil

    graph.mutate!(turn_id: turn_id) do |m|
      user =
        m.create_node(
          node_type: Messages::UserMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: conversation.chat_lane.id,
          content: "Try to edit AGENTS.md",
          metadata: {},
        )
      first_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: conversation.chat_lane.id,
          body_output: { "content" => "I will inspect AGENTS.md first." },
          metadata: {},
        )
      read_task =
        m.create_node(
          node_type: Messages::Task.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: conversation.chat_lane.id,
          body_input: { "name" => "read", "requested_name" => "read" },
          body_output: { "result" => AgentCore::Resources::Tools::ToolResult.success(text: "governance file").to_h },
          metadata: {},
        )
      final_agent =
        m.create_node(
          node_type: Messages::AgentMessage.node_type_key,
          state: DAG::Node::FINISHED,
          lane_id: conversation.chat_lane.id,
          body_output: { "content" => "I won’t alter AGENTS.md because it is protected." },
          metadata: { "generated_by" => "agent_core.tool_loop" },
        )

      m.create_edge(from_node: user, to_node: first_agent, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: first_agent, to_node: read_task, edge_type: DAG::Edge::SEQUENCE)
      m.create_edge(from_node: read_task, to_node: final_agent, edge_type: DAG::Edge::SEQUENCE)
    end

    selected = runner.send(:final_agent_node_for_turn!, conversation: conversation, turn_id: turn_id)

    assert_equal final_agent.id, selected.id
    assert_equal "I won’t alter AGENTS.md because it is protected.", selected.body_output.fetch("content")
  end

  test "agents_mutation_refusal? accepts unicode refusal phrasing from real models" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    content = "I can’t do that. `../../AGENTS.md` is a governance file, and I won’t alter it."

    assert runner.send(:agents_mutation_refusal?, content)
  end

  test "require_memory_lookup! accepts memory_store payload as fallback evidence when no lookup task exists" do
    task =
      Struct.new(:id, :body_input, :body_output).new(
        "task-1",
        {
          "name" => "memory_store",
          "arguments" => {
            "scope" => "conversation",
            "content" => "TOKEN-123",
            "mode" => "append",
          },
        },
        {
          "result" =>
            AgentCore::Resources::Tools::ToolResult.success(
              text: JSON.generate(
                {
                  "document" => {
                    "scope" => "conversation",
                    "body" => "TOKEN-123",
                  },
                },
              ),
            ).to_h,
        },
      )
    runner_class =
      Class.new(Cybros::LiveAcceptance::AgentRootWorkspace::Runner) do
        def initialize(task:, **kwargs)
          super(**kwargs)
          @task = task
        end

        private

          def turn_tasks(agent_node)
            _ = agent_node
            [@task]
          end
      end
    runner = runner_class.new(task: task, io: StringIO.new)

    payload =
      runner.send(
        :require_memory_lookup!,
        Object.new,
        token: "TOKEN-123",
        expected_scope: "conversation",
        allow_store_fallback: true,
      )

    assert_equal "conversation", payload.dig("document", "scope")
    assert_equal "TOKEN-123", payload.dig("document", "body")
  end

  test "performable_job_arguments unwraps ruby2_keywords payloads from the test adapter" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    entry = {
      job: DAG::TickGraphJob,
      args: [
        "graph-123",
        {
          "limit" => 10,
          "_aj_ruby2_keywords" => ["limit"],
        },
      ],
    }

    args, kwargs = runner.send(:performable_job_arguments, entry)

    assert_equal ["graph-123"], args
    assert_equal({ limit: 10 }, kwargs)
  end

  test "compaction seed targets the soft-limit window instead of filling the entire hard cap" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    model_ref = "openrouter/openai-gpt-5.4-live-acceptance"

    budget = runner.send(:effective_context_window_tokens_for, model_ref: model_ref)
    chunk_tokens = runner.send(:compaction_seed_chunk_tokens_for, model_ref: model_ref)

    assert_operator chunk_tokens, :positive?
    assert_operator chunk_tokens, :<, (budget * 0.03)
  end

  test "content_for_minimum_tokens grows incrementally so nearby thresholds do not collapse to the same chunk" do
    runner = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(io: StringIO.new)
    token_counter = runner.send(:token_counter_for, model_ref: "dev/mock-model")

    first = runner.send(:content_for_minimum_tokens, token_counter: token_counter, minimum_tokens: 1000)
    second = runner.send(:content_for_minimum_tokens, token_counter: token_counter, minimum_tokens: 1100)

    assert_operator token_counter.count_text(second), :>, token_counter.count_text(first)
  end

  test "run_compaction_durability! falls back to the next offline-probed candidate when the first live attempt fails" do
    summary_entry = Struct.new(:seq).new(10)
    fake_entries_class =
      Class.new do
        def initialize(summary_entry:)
          @summary_entry = summary_entry
        end

        def where(buffer_name:)
          _ = buffer_name
          self
        end

        def ordered
          self
        end

        def last
          @summary_entry
        end
      end

    fake_runner_class =
      Class.new(Cybros::LiveAcceptance::AgentRootWorkspace::Runner) do
        def initialize(summary_entry:, entries_class:, **kwargs)
          super(**kwargs)
          @summary_entry = summary_entry
          @entries_class = entries_class
          @attempt_index = 0
          @conversations = []
        end

        private

          def compaction_seed_turn_candidates
            [15, 16]
          end

          def create_live_conversation!(agent:, title:, metadata: nil)
            _ = agent
            _ = title
            _ = metadata
            @attempt_index += 1
            lane = Struct.new(:lane_prompt_buffer_entries).new(nil)
            conversation = Struct.new(:id, :chat_lane).new("conversation-#{@attempt_index}", lane)
            lane.lane_prompt_buffer_entries =
              if @attempt_index == 1
                Object.new.tap do |entries|
                  entries.define_singleton_method(:where) { |buffer_name:| _ = buffer_name; self }
                  entries.define_singleton_method(:ordered) { self }
                  entries.define_singleton_method(:last) { nil }
                end
              else
                @entries_class.new(summary_entry: @summary_entry)
              end
            @conversations << conversation
            conversation
          end

          def seed_compaction_history!(conversation:, model_ref:, max_seed_turns: nil)
            _ = conversation
            _ = model_ref
            _ = max_seed_turns
          end

          def probe_compaction_turn!(conversation:, model_ref:)
            _ = model_ref
            {
              turn_id: "turn-for-#{conversation.id}",
              context_budget: { "budget_action" => "enqueue_compact", "budget_state" => "near_hard_cap" },
              context_cost: {
                "estimated_tokens" => {
                  "total" => conversation.id == "conversation-1" ? 26_050 : 26_400,
                },
              },
            }
          end

          def complete_prepared_turn!(conversation:, turn_id:)
            _ = turn_id
            reason = conversation.id == "conversation-1" ? "provider_limit" : nil
            { agent_node: Struct.new(:metadata).new(reason ? { "reason" => reason } : { "conversation_id" => conversation.id }), approval_count: 0 }
          end

          def find_tool_task(agent_node, *logical_names)
            _ = logical_names
            return nil if agent_node.metadata["reason"] == "provider_limit"
            return nil if agent_node.metadata["conversation_id"] != "conversation-2"

            Struct.new(:body_output).new(
              {
                "result" => AgentCore::Resources::Tools::ToolResult.success(text: "compacted").to_h,
              },
            )
          end
      end
    runner = fake_runner_class.new(summary_entry: summary_entry, entries_class: fake_entries_class, io: StringIO.new)

    result = runner.send(:run_compaction_durability!, agent: :fake, model_ref: "dev/mock-model", run_index: 1)

    assert_equal 0, result.fetch(:approval_count)
    assert_equal ["conversation-1", "conversation-2"], result.fetch(:conversation_ids)
    assert_equal "summary_seq=10", result.fetch(:note)
  end

  test "run_compaction_durability! selects the first offline-probed near-hard-cap candidate before running the live turn" do
    summary_entry = Struct.new(:seq).new(12)
    fake_entries_class =
      Class.new do
        def initialize(summary_entry:)
          @summary_entry = summary_entry
        end

        def where(buffer_name:)
          _ = buffer_name
          self
        end

        def ordered
          self
        end

        def last
          @summary_entry
        end
      end

    fake_runner_class =
      Class.new(Cybros::LiveAcceptance::AgentRootWorkspace::Runner) do
        attr_reader :completed_turn_ids

        def initialize(summary_entry:, entries_class:, **kwargs)
          super(**kwargs)
          @summary_entry = summary_entry
          @entries_class = entries_class
          @conversations = []
          @completed_turn_ids = []
        end

        private

          def compaction_seed_turn_candidates
            [13, 17, 15]
          end

          def create_live_conversation!(agent:, title:, metadata: nil)
            _ = agent
            _ = title
            _ = metadata
            index = @conversations.length + 1
            lane = Struct.new(:lane_prompt_buffer_entries).new(nil)
            conversation = Struct.new(:id, :chat_lane).new("conversation-#{index}", lane)
            lane.lane_prompt_buffer_entries =
              if index == 3
                @entries_class.new(summary_entry: @summary_entry)
              else
                Object.new.tap do |entries|
                  entries.define_singleton_method(:where) { |buffer_name:| _ = buffer_name; self }
                  entries.define_singleton_method(:ordered) { self }
                  entries.define_singleton_method(:last) { nil }
                end
              end
            @conversations << conversation
            conversation
          end

          def seed_compaction_history!(conversation:, model_ref:, max_seed_turns: nil)
            _ = conversation
            _ = model_ref
            _ = max_seed_turns
          end

          def probe_compaction_turn!(conversation:, model_ref:)
            _ = model_ref
            case conversation.id
            when "conversation-1"
              {
                turn_id: "turn-none",
                context_budget: { "budget_action" => "none", "budget_state" => "normal" },
                context_cost: { "estimated_tokens" => { "total" => 24_500 } },
              }
            when "conversation-2"
              {
                turn_id: "turn-forced-fit",
                context_budget: { "budget_action" => "enqueue_compact", "budget_state" => "forced_fit" },
                context_cost: { "estimated_tokens" => { "total" => 27_200 } },
              }
            else
              {
                turn_id: "turn-near-hard-cap",
                context_budget: { "budget_action" => "enqueue_compact", "budget_state" => "near_hard_cap" },
                context_cost: { "estimated_tokens" => { "total" => 26_100 } },
              }
            end
          end

          def complete_prepared_turn!(conversation:, turn_id:)
            @completed_turn_ids << turn_id
            {
              agent_node: Struct.new(:metadata).new({ "conversation_id" => conversation.id }),
              approval_count: 0,
            }
          end

          def find_tool_task(agent_node, *logical_names)
            _ = logical_names
            return unless agent_node.metadata["conversation_id"] == "conversation-3"

            Struct.new(:body_output).new(
              {
                "result" => AgentCore::Resources::Tools::ToolResult.success(text: "compacted").to_h,
              },
            )
          end
      end

    runner = fake_runner_class.new(summary_entry: summary_entry, entries_class: fake_entries_class, io: StringIO.new)

    result = runner.send(:run_compaction_durability!, agent: :fake, model_ref: "dev/mock-model", run_index: 1)

    assert_equal ["turn-near-hard-cap"], runner.completed_turn_ids
    assert_equal ["conversation-1", "conversation-2", "conversation-3"], result.fetch(:conversation_ids)
    assert_equal "summary_seq=12", result.fetch(:note)
  end

  private

    def create_program!
      create_agent_record!(
        name: "Fixture Program",
        config_namespace: "fixture.program.#{SecureRandom.hex(4)}",
        published_contract_fingerprint: "contract:v1",
        manifest_snapshot: {
          "agent_key" => "fixture-program",
          "name" => "Fixture Program",
        },
        global_config: {},
        global_config_schema: { "type" => "object" },
        conversation_config_schema: { "type" => "object" },
        config_schema_fingerprint: "config:v1",
      )
    end

    def create_active_deployment!(program:, endpoint_url:)
      create_runtime_binding_record!(
        agent: program,
        transport_kind: "http_jsonrpc",
        endpoint_url: endpoint_url,
        deployment_bearer_secret_ref: "secret://fixture",
        contract_fingerprint: program.published_contract_fingerprint,
        deployment_fingerprint: "fixture-deployment-v1",
        status: "active",
        health_status: "healthy",
        protocol_version: "agent_rpc.v1",
        agent_sdk_version: "fixture-ruby-sdk/1.0",
        supported_methods: Agents::Protocol::REQUIRED_METHODS,
        manifest_snapshot: {},
        schema_snapshot: {},
        capability_snapshot: {},
        inspection_details: {},
        activated_at: Time.current.change(usec: 0),
      )
    end

    def create_programmable_conversation!(program:, llm_options: nil)
      location =
        create_execution_location_profile!(
          name: "Primary host",
          kind: "host",
          platform: "macos_arm64",
          status: "active",
          trust_group: "operator",
          environment: "development",
          tags: ["fixture"],
          max_concurrent_tasks: 4,
          max_queued_tasks: 16,
          default_timeout_s: 900,
        )
      workspace =
        create_workspace_profile!(
          execution_location: location,
          name: "Primary workspace",
          root_path: "/tmp/live-acceptance-#{SecureRandom.hex(4)}",
          workspace_type: "git",
          status: "active",
          capability_tags: ["git"],
          tags: ["fixture"],
        )
      target =
        create_execution_profile!(
          execution_location: location,
          workspace: workspace,
          name: "Primary target",
          status: "active",
          sandboxed: true,
        )

      conversation = create_conversation!(title: "Programmable live acceptance")
      agent = create_agent_runtime!(agent: program, execution_profile: target)
      conversation.update!(
        agent: agent,
        permission_mode: "default",
        agent_config: {
          program.config_namespace => {
            "llm_options" => llm_options || {},
          },
        },
        agent_config_schema_fingerprint: program.config_schema_fingerprint,
      )
      conversation
    end
end
