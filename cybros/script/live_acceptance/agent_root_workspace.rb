require "fileutils"
require "json"
require "optparse"
require "pathname"
require "socket"
require "tmpdir"

module Cybros
  module LiveAcceptance
    module AgentRootWorkspace
      ScenarioFailure = Class.new(StandardError)

      Scenario =
        Data.define(:id, :label, :requires_approval) do
          def requires_approval? = requires_approval == true
        end

      class Runner
        REPORT_PATH = Rails.root.join("docs/reports/2026-03-16-agent-root-workspace-proof.md")
        RUNS_PER_SCENARIO = 3
        APPROVAL_DRIVER = :approve_awaiting_nodes
        DEFAULT_APPROVER = "live-acceptance:harness"
        DEFAULT_MODEL_FALLBACK = "openrouter/openai-gpt-5.4".freeze

        SCENARIOS = [
          Scenario.new(id: "root_shared_memory", label: "Root shared memory", requires_approval: false),
          Scenario.new(id: "conversation_isolation", label: "Conversation isolation", requires_approval: false),
          Scenario.new(id: "lane_local_memory_isolation", label: "Lane-local memory isolation", requires_approval: false),
          Scenario.new(id: "branch_snapshot_inheritance", label: "Branch snapshot inheritance", requires_approval: false),
          Scenario.new(id: "directory_complexity_tolerance", label: "Directory complexity tolerance", requires_approval: false),
          Scenario.new(id: "compaction_durability", label: "Compaction durability", requires_approval: false),
          Scenario.new(id: "self_mutate_soul", label: "Self-mutate SOUL.md", requires_approval: true),
          Scenario.new(id: "self_mutate_user", label: "Self-mutate USER.md", requires_approval: true),
          Scenario.new(id: "create_agent_local_skill", label: "Create agent-local skill", requires_approval: true),
          Scenario.new(id: "modify_agent_local_skill", label: "Modify agent-local skill", requires_approval: true),
          Scenario.new(id: "deny_agents_mutation", label: "Deny AGENTS.md mutation", requires_approval: false),
        ].freeze

        def self.parse_options(argv)
          options = {
            model_ref: ENV["AGENT_ROOT_WORKSPACE_MODEL_REF"].to_s.strip.presence,
            report_path: ENV["AGENT_ROOT_WORKSPACE_REPORT_PATH"].to_s.strip.presence,
            workspace_root_base: ENV["AGENT_ROOT_WORKSPACE_BASE"].to_s.strip.presence,
            keep_workspace_root: ENV["AGENT_ROOT_WORKSPACE_KEEP_ROOT"].to_s.strip != "0",
            runs_per_scenario: Integer(ENV.fetch("AGENT_ROOT_WORKSPACE_RUNS_PER_SCENARIO", RUNS_PER_SCENARIO), exception: false) || RUNS_PER_SCENARIO,
          }

          OptionParser.new do |parser|
            parser.banner = "Usage: bin/rails runner script/live_acceptance/agent_root_workspace.rb [options]"

            parser.on("--model-ref MODEL_REF", "Model ref for the live run") { |value| options[:model_ref] = value }
            parser.on("--report-path PATH", "Proof markdown output path") { |value| options[:report_path] = value }
            parser.on("--workspace-root-base PATH", "Temporary agent workspace root base") { |value| options[:workspace_root_base] = value }
            parser.on("--cleanup", "Delete the temporary agent workspace root after the run") { options[:keep_workspace_root] = false }
            parser.on("--keep-workspace-root", "Keep the temporary agent workspace root after the run") { options[:keep_workspace_root] = true }
            parser.on("--runs N", Integer, "Consecutive passes required per scenario") { |value| options[:runs_per_scenario] = value }
          end.parse!(Array(argv))

          options
        end

        def initialize(model_ref: nil, report_path: REPORT_PATH, workspace_root_base: nil, keep_workspace_root: true, runs_per_scenario: RUNS_PER_SCENARIO, io: $stdout)
          @io = io
          @report_path = Pathname.new(report_path || REPORT_PATH)
          @workspace_root_base = workspace_root_base.present? ? Pathname.new(workspace_root_base) : Pathname.new(Dir.mktmpdir("cybros-agent-root-live-"))
          @keep_workspace_root = keep_workspace_root == true
          @created_workspace_root_base = workspace_root_base.blank?
          @runs_per_scenario = Integer(runs_per_scenario, exception: false) || RUNS_PER_SCENARIO
          @model_ref = model_ref.to_s.strip.presence
        end

        attr_reader :io, :report_path, :workspace_root_base, :runs_per_scenario

        def run!
          ensure_valid_run_count!
          ensure_live_provider_ready!

          started_at = Time.current.utc
          original_queue_adapter = ActiveJob::Base.queue_adapter
          original_agent_workspace_root = runtime_setting_record.agent_workspace_root

          ActiveJob::Base.queue_adapter = :test
          runtime_setting_record.update!(agent_workspace_root: workspace_root_base.to_s)
          FileUtils.mkdir_p(workspace_root_base)

          agent = Agents::BootstrapBundledDefaultService.ensure_agent!
          model_ref = resolved_model_ref

          say("Running agent-root workspace live acceptance")
          say("Model ref: #{model_ref}")
          say("Workspace root base: #{workspace_root_base}")
          say("Report path: #{report_path}")

          results = SCENARIOS.map { |scenario| run_series_for(scenario, agent: agent, model_ref: model_ref) }
          finished_at = Time.current.utc

          markdown =
            proof_markdown(
              started_at: started_at,
              finished_at: finished_at,
              model_ref: model_ref,
              environment_label: "#{Rails.env} @ #{Socket.gethostname}",
              results: results,
            )

          FileUtils.mkdir_p(report_path.dirname)
          report_path.write(markdown)

          failed = results.reject { |entry| entry.fetch(:success) }
          if failed.any?
            raise ScenarioFailure, "Live acceptance failed for: #{failed.map { |entry| entry.fetch(:id) }.join(", ")}"
          end

          say("All #{SCENARIOS.length} live scenarios passed #{runs_per_scenario} consecutive times.")
          say("Proof written to #{report_path}")
          true
        ensure
          ActiveJob::Base.queue_adapter = original_queue_adapter if original_queue_adapter
          runtime_setting_record.update!(agent_workspace_root: original_agent_workspace_root) if original_agent_workspace_root.present?
          if @created_workspace_root_base && @keep_workspace_root != true
            FileUtils.rm_rf(workspace_root_base)
          end
        end

        def proof_markdown(started_at:, finished_at:, model_ref:, environment_label:, results:)
          lines = []
          lines << "# Agent Root Workspace Proof"
          lines << ""
          lines << "- Date: #{finished_at.to_date.iso8601}"
          lines << "- Started at (UTC): #{started_at.utc.iso8601}"
          lines << "- Finished at (UTC): #{finished_at.utc.iso8601}"
          lines << "- Model ref: #{model_ref}"
          lines << "- Environment: #{environment_label}"
          lines << "- Approval driver: `#{APPROVAL_DRIVER}`"
          lines << "- Runs per scenario: #{runs_per_scenario}"
          lines << "- Workspace root base: `#{workspace_root_base}`"
          lines << ""
          lines << "## Scenario outcomes"
          lines << ""
          lines << "| Scenario | Run | Status | Approvals | Conversation ids | Note |"
          lines << "| --- | --- | --- | --- | --- | --- |"

          Array(results).each do |series|
            Array(series.fetch(:runs)).each do |run|
              lines << [
                "| #{series.fetch(:label)}",
                run.fetch(:index),
                run.fetch(:success) ? "PASS" : "FAIL",
                run.fetch(:approval_count),
                run.fetch(:conversation_ids).join(", "),
                (run.fetch(:note).presence || run.fetch(:error).to_s).gsub("|", "\\|"),
                "|",
              ].join(" ")
            end
          end

          lines << ""
          lines << "## Scenario summary"
          lines << ""

          Array(results).each do |series|
            status = series.fetch(:success) ? "PASS" : "FAIL"
            lines << "- #{series.fetch(:label)}: #{status}"
          end

          lines.join("\n") + "\n"
        end

        private

          def ensure_valid_run_count!
            raise ArgumentError, "runs_per_scenario must be >= 1" if runs_per_scenario <= 0
          end

          def runtime_setting_record
            @runtime_setting_record ||= RuntimeSetting.find_or_create_by!(scope_key: "instance") do |record|
              record.default_worker_concurrency = RuntimeSetting::DEFAULT_WORKER_CONCURRENCY
              record.agent_workspace_root = RuntimeSetting.default_agent_workspace_root.presence || Dir.mktmpdir("cybros-agent-runtime-setting-")
              record.queue_overrides = {}
              record.alert_thresholds = {}
            end
          end

          def resolved_model_ref
            @resolved_model_ref ||= begin
              configured = @model_ref.presence || Account.instance.llm_default_model_ref.to_s.strip
              return configured if model_ref_usable?(configured)

              return DEFAULT_MODEL_FALLBACK if model_ref_usable?(DEFAULT_MODEL_FALLBACK)

              raise ScenarioFailure, "No usable live model ref found. Configure credentials or pass --model-ref."
            end
          end

          def ensure_live_provider_ready!
            api_key = ENV["OPENROUTER_API_KEY"].to_s.strip
            return if api_key.empty?

            credential = LLMProviderCredential.find_or_initialize_by(provider_key: "openrouter")
            credential.assign_attributes(
              credential_type: "api_key",
              status: "active",
              api_key: api_key,
            )
            credential.save! if credential.new_record? || credential.changed?
          end

          def model_ref_usable?(model_ref)
            ref = model_ref.to_s.strip
            return false if ref.empty?

            Cybros::AgentRuntimeResolver.validate_model_ref!(model_ref: ref)
            true
          rescue StandardError
            false
          end

          def model_ref_defined?(model_ref)
            provider_key, model_key = model_ref.to_s.split("/", 2)
            return false if provider_key.blank? || model_key.blank?

            Cybros::LLM::Catalog.effective.model(provider_key, model_key)
            true
          rescue StandardError
            false
          end

          def scenario_model_ref_for(scenario_id:, model_ref:)
            scenario_key = scenario_id.to_s
            requested = model_ref.to_s
            return requested unless scenario_key == "compaction_durability"
            return requested if requested.end_with?("-live-acceptance")

            provider_key, model_key = requested.split("/", 2)
            return requested if provider_key.blank? || model_key.blank?

            candidate = "#{provider_key}/#{model_key}-live-acceptance"
            model_ref_defined?(candidate) ? candidate : requested
          end

          def run_series_for(scenario, agent:, model_ref:)
            say("")
            say("Scenario: #{scenario.label}")

            runs = []

            runs_per_scenario.times do |index|
              reset_agent_root!(agent)
              run_index = index + 1
              scenario_model_ref = scenario_model_ref_for(scenario_id: scenario.id, model_ref: model_ref)

              begin
                details = send("run_#{scenario.id}!", agent: agent, model_ref: scenario_model_ref, run_index: run_index)
                runs << {
                  index: run_index,
                  success: true,
                  approval_count: details.fetch(:approval_count, 0),
                  conversation_ids: Array(details.fetch(:conversation_ids, [])),
                  note: details.fetch(:note, ""),
                  error: "",
                }
                say("  PASS run #{run_index}/#{runs_per_scenario}: #{details.fetch(:note, "")}")
              rescue StandardError => e
                runs << {
                  index: run_index,
                  success: false,
                  approval_count: 0,
                  conversation_ids: [],
                  note: "",
                  error: "#{e.class}: #{e.message}",
                }
                say("  FAIL run #{run_index}/#{runs_per_scenario}: #{e.class}: #{e.message}")
                break
              end
            end

            {
              id: scenario.id,
              label: scenario.label,
              requires_approval: scenario.requires_approval?,
              success: runs.length == runs_per_scenario && runs.all? { |entry| entry.fetch(:success) },
              runs: runs,
            }
          end

          def reset_agent_root!(agent)
            FileUtils.rm_rf(agent.workspace_root_path)
          end

          def run_root_shared_memory!(agent:, model_ref:, run_index:)
            token = "ROOT_SHARED_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            first = create_live_conversation!(agent: agent, title: "Root shared #{run_index} A")
            second = create_live_conversation!(agent: agent, title: "Root shared #{run_index} B")

            store_turn =
              submit_turn!(
                conversation: first,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the memory tool `memory_store` with these exact arguments:
                  {"scope":"root","content":"#{token}","mode":"append"}

                  Store the exact line in durable root memory.
                  Then verify it with `memory_get` or `memory_search` on root scope.
                  If the first write lands in the wrong scope, fix it and verify again before you finish.
                  Do not write files directly.
                PROMPT
              )
            read_turn =
              submit_turn!(
                conversation: second,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the memory tool `memory_get` with these exact arguments:
                  {"scope":"root","target":"MEMORY.md"}

                  Read the current durable root memory file.
                  Confirm whether it contains the exact line "#{token}".
                PROMPT
              )

            assert_includes first.agent.workspace_root_path.join("MEMORY.md").read, token
            require_memory_lookup!(store_turn.fetch(:agent_node), token: token, expected_scope: "root", allow_store_fallback: true)

            read_payload = require_memory_lookup!(read_turn.fetch(:agent_node), token: token, expected_scope: "root")
            ensure!(Array(read_payload["matches"]).any? || read_payload.dig("document", "body").to_s.include?(token), "expected root memory lookup to find #{token}")

            {
              approval_count: store_turn.fetch(:approval_count) + read_turn.fetch(:approval_count),
              conversation_ids: [first.id, second.id],
              note: "token=#{token}",
            }
          end

          def run_conversation_isolation!(agent:, model_ref:, run_index:)
            token = "CONVERSATION_ONLY_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            first = create_live_conversation!(agent: agent, title: "Conversation isolation #{run_index} A")
            second = create_live_conversation!(agent: agent, title: "Conversation isolation #{run_index} B")

            store_turn =
              submit_turn!(
                conversation: first,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the memory tool `memory_store` with these exact arguments:
                  {"scope":"conversation","content":"#{token}","mode":"append"}

                  Store the exact line in conversation-scoped memory.
                  Then verify it with `memory_get` or `memory_search` on conversation scope.
                  If the first write lands in the wrong scope, fix it and verify again before you finish.
                  Do not store it in root or lane memory.
                PROMPT
              )
            lookup_turn =
              submit_turn!(
                conversation: second,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the memory tool `memory_search` with these exact arguments:
                  {"query":"#{token}","scopes":["conversation"]}

                  Search only conversation-scoped memory for the exact line.
                  Report that it is absent if it is not found.
                PROMPT
              )

            store_task = require_tool_task!(store_turn.fetch(:agent_node), "memory_store")
            store_payload = parsed_tool_payload(store_task)
            ensure!(store_payload.dig("document", "scope").to_s == "conversation", "expected conversation-scoped store payload")
            ensure!(store_payload.dig("document", "body").to_s.include?(token), "expected conversation store payload to include #{token}")
            require_memory_lookup!(store_turn.fetch(:agent_node), token: token, expected_scope: "conversation", allow_store_fallback: true)

            payload = require_memory_lookup!(lookup_turn.fetch(:agent_node), expected_scope: "conversation")
            ensure!(Array(payload["matches"]).empty? && payload.dig("document", "body").to_s.exclude?(token), "expected conversation memory to stay isolated")

            {
              approval_count: store_turn.fetch(:approval_count) + lookup_turn.fetch(:approval_count),
              conversation_ids: [first.id, second.id],
              note: "isolated token=#{token}",
            }
          end

          def run_lane_local_memory_isolation!(agent:, model_ref:, run_index:)
            token = "LANE_ONLY_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            first = create_live_conversation!(agent: agent, title: "Lane isolation #{run_index} A")
            second = create_live_conversation!(agent: agent, title: "Lane isolation #{run_index} B")

            store_turn =
              submit_turn!(
                conversation: first,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the memory tool `memory_store` with these exact arguments:
                  {"scope":"lane","content":"#{token}","mode":"append"}

                  Store the exact line in lane-scoped memory.
                  Then verify it with `memory_get` or `memory_search` on lane scope.
                  If the first write lands in the wrong scope, fix it and verify again before you finish.
                  Do not write it to conversation or root memory.
                PROMPT
              )
            lookup_turn =
              submit_turn!(
                conversation: second,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the memory tool `memory_search` with these exact arguments:
                  {"query":"#{token}","scopes":["lane"]}

                  Search only lane-scoped memory for the exact line.
                  Report that it is absent if it is not found.
                PROMPT
              )

            store_task = require_tool_task!(store_turn.fetch(:agent_node), "memory_store")
            store_payload = parsed_tool_payload(store_task)
            ensure!(store_payload.dig("document", "scope").to_s == "lane", "expected lane-scoped store payload")
            ensure!(store_payload.dig("document", "body").to_s.include?(token), "expected lane store payload to include #{token}")
            ensure!(store_payload.dig("document", "path").to_s.include?("/.lanes/"), "expected lane-scoped store path to stay under .lanes")
            require_memory_lookup!(store_turn.fetch(:agent_node), token: token, expected_scope: "lane", allow_store_fallback: true)
            ensure!(!first.workspace_root_path.join("MEMORY.md").exist? || first.workspace_root_path.join("MEMORY.md").read.exclude?(token), "lane token leaked into conversation memory")

            payload = require_memory_lookup!(lookup_turn.fetch(:agent_node), expected_scope: "lane")
            ensure!(Array(payload["matches"]).empty? && payload.dig("document", "body").to_s.exclude?(token), "expected lane memory to stay local")

            {
              approval_count: store_turn.fetch(:approval_count) + lookup_turn.fetch(:approval_count),
              conversation_ids: [first.id, second.id],
              note: "lane token=#{token}",
            }
          end

          def run_branch_snapshot_inheritance!(agent:, model_ref:, run_index:)
            token = "BRANCH_SNAPSHOT_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            parent = create_live_conversation!(agent: agent, title: "Branch snapshot #{run_index}")

            parent_turn =
              submit_turn!(
                conversation: parent,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the memory tool `memory_store` with these exact arguments:
                  {"scope":"conversation","content":"#{token}","mode":"append"}

                  Store the exact line in conversation-scoped memory.
                  Then verify it with `memory_get` or `memory_search` on conversation scope.
                  If the first write lands in the wrong scope, fix it and verify again before you finish.
                PROMPT
              )

            child =
              parent.create_child!(
                from_node_id: parent_turn.fetch(:agent_node).id,
                kind: "branch",
                title: "Branch child #{run_index}",
                user_content: "",
              )

            child_turn =
              submit_turn!(
                conversation: child,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the memory tool `memory_search` with these exact arguments:
                  {"query":"#{token}","scopes":["conversation"]}

                  Find the exact line in conversation-scoped memory.
                  Reply with the exact line if you find it.
                PROMPT
              )

            parent_memory = parent.workspace_root_path.join("MEMORY.md").read
            child_memory = child.workspace_root_path.join("MEMORY.md").read
            ensure!(parent_memory == child_memory, "child conversation memory snapshot diverged from parent")

            payload = require_memory_lookup!(child_turn.fetch(:agent_node), token: token, expected_scope: "conversation")
            ensure!(Array(payload["matches"]).any? || payload.dig("document", "body").to_s.include?(token), "expected child branch to inherit conversation memory snapshot")

            {
              approval_count: parent_turn.fetch(:approval_count) + child_turn.fetch(:approval_count),
              conversation_ids: [parent.id, child.id],
              note: "branch token=#{token}",
            }
          end

          def run_directory_complexity_tolerance!(agent:, model_ref:, run_index:)
            token = "DIRECTORY_COMPLEXITY_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            conversation = create_live_conversation!(agent: agent, title: "Directory complexity #{run_index}")
            Conversations::WorkspaceInitializer.initialize!(conversation: conversation)
            seed_directory_noise!(conversation.workspace_root_path)

            turn =
              submit_turn!(
                conversation: conversation,
                model_ref: model_ref,
                content: <<~PROMPT,
                  In the current conversation workspace, create the file artifacts/complexity-proof.txt.
                  Its entire content must be "#{token}" followed by a newline.
                PROMPT
              )

            write_task = require_tool_task!(turn.fetch(:agent_node), "write", "edit", "apply_patch")
            written_file = conversation.workspace_root_path.join("artifacts/complexity-proof.txt")
            ensure!(written_file.file?, "expected artifacts/complexity-proof.txt to exist")
            ensure!(written_file.read == "#{token}\n", "unexpected file content in artifacts/complexity-proof.txt")
            ensure!(task_succeeded?(write_task), "expected file mutation task to succeed")

            {
              approval_count: turn.fetch(:approval_count),
              conversation_ids: [conversation.id],
              note: "artifact token=#{token}",
            }
          end

          def run_compaction_durability!(agent:, model_ref:, run_index:)
            conversation_ids = []
            last_failure_message = nil
            probe_attempts = []

            compaction_seed_turn_candidates.each do |max_seed_turns|
              conversation =
                create_live_conversation!(
                  agent: agent,
                  title: "Compaction durability #{run_index}",
                  metadata: {
                    "agent" => {},
                    "input_policy" => {
                      "input_coalescing" => { "enabled" => false },
                      "oversize" => {
                        "multi_message" => { "strategy" => "compact_context" },
                      },
                    },
                  },
                )
              conversation_ids << conversation.id

              seed_compaction_history!(conversation: conversation, model_ref: model_ref, max_seed_turns: max_seed_turns)
              probe =
                probe_compaction_turn!(
                  conversation: conversation,
                  model_ref: model_ref,
                )
              probe_attempts << {
                conversation: conversation,
                max_seed_turns: max_seed_turns,
                probe: probe,
              }
            end

            ordered_compaction_probe_candidates(probe_attempts).each do |attempt|
              turn =
                complete_prepared_turn!(
                  conversation: attempt.fetch(:conversation),
                  turn_id: attempt.fetch(:probe).fetch(:turn_id),
                )

              compact_task = find_tool_task(turn.fetch(:agent_node), "compact_context")
              if compact_task.present?
                ensure!(task_succeeded?(compact_task), "expected compact_context to succeed")

                latest_summary =
                  attempt.fetch(:conversation).chat_lane.lane_prompt_buffer_entries.where(buffer_name: "summaries").ordered.last
                if latest_summary.present?
                  return {
                    approval_count: turn.fetch(:approval_count),
                    conversation_ids: conversation_ids,
                    note: "summary_seq=#{latest_summary.seq}",
                  }
                end

                last_failure_message = "expected compaction to flush a lane summary entry"
                next
              end

              failure_reason = turn.fetch(:agent_node).metadata.fetch("reason", nil).to_s.presence
              attempted_budget =
                attempt.fetch(:probe).fetch(:context_budget, {}).slice("budget_action", "budget_state")
              attempted_budget["estimated_tokens"] =
                attempt.fetch(:probe).dig(:context_cost, "estimated_tokens", "total")
              last_failure_message =
                [
                  (failure_reason.present? ? "expected a task for compact_context (agent reason=#{failure_reason})" : "expected a task for compact_context"),
                  attempted_budget.compact.presence,
                ].compact.join(" | ")
            end

            last_failure_message ||= "expected a compaction probe candidate with enqueue_compact (#{compaction_probe_summary_for(probe_attempts)})"
            raise ScenarioFailure, last_failure_message
          end

          def run_self_mutate_soul!(agent:, model_ref:, run_index:)
            token = "SOUL_MUTATION_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            conversation = create_live_conversation!(agent: agent, title: "Soul mutate #{run_index}")
            original = conversation.agent.workspace_root_path.join("SOUL.md").read

            turn =
              submit_turn!(
                conversation: conversation,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the self-mutate skill to append the exact line "#{token}" to the live root file ../../SOUL.md.
                  Do not create or modify a conversation-local SOUL.md shadow file.
                  The live acceptance harness will drive the product approval gate programmatically once you issue the protected write tool call.
                  Do not stop for conversational confirmation; proceed to the protected write path and do not use exec to write the file.
                PROMPT
              )

            ensure!(turn.fetch(:approval_count).positive?, "expected protected SOUL.md write to require approval")
            ensure!(conversation.agent.workspace_root_path.join("SOUL.md").read.include?(token), "expected SOUL.md to include #{token}")
            ensure_history_snapshot!(conversation.agent.workspace_root_path, relative_path: "SOUL.md", original_body: original)

            {
              approval_count: turn.fetch(:approval_count),
              conversation_ids: [conversation.id],
              note: "soul token=#{token}",
            }
          end

          def run_self_mutate_user!(agent:, model_ref:, run_index:)
            token = "USER_MUTATION_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            conversation = create_live_conversation!(agent: agent, title: "User mutate #{run_index}")
            original = conversation.agent.workspace_root_path.join("USER.md").read

            turn =
              submit_turn!(
                conversation: conversation,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the self-mutate skill to append the exact line "#{token}" to the live root file ../../USER.md.
                  Do not create or modify a conversation-local USER.md shadow file.
                  The live acceptance harness will drive the product approval gate programmatically once you issue the protected write tool call.
                  Do not stop for conversational confirmation; proceed to the protected write path and do not use exec to write the file.
                PROMPT
              )

            ensure!(turn.fetch(:approval_count).positive?, "expected protected USER.md write to require approval")
            ensure!(conversation.agent.workspace_root_path.join("USER.md").read.include?(token), "expected USER.md to include #{token}")
            ensure_history_snapshot!(conversation.agent.workspace_root_path, relative_path: "USER.md", original_body: original)

            {
              approval_count: turn.fetch(:approval_count),
              conversation_ids: [conversation.id],
              note: "user token=#{token}",
            }
          end

          def run_create_agent_local_skill!(agent:, model_ref:, run_index:)
            token = "CREATE_SKILL_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            skill_name = "live-acceptance-#{run_index}-#{SecureRandom.hex(3)}"
            conversation = create_live_conversation!(agent: agent, title: "Create skill #{run_index}")

            turn =
              submit_turn!(
                conversation: conversation,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the self-mutate skill to create a new agent-local skill named "#{skill_name}" under the live root path ../../skills/#{skill_name}/SKILL.md.
                  Do not create a conversation-local skills/ shadow directory.
                  Use this YAML frontmatter:
                  name: #{skill_name}
                  description: Returns #{token}

                  After the frontmatter, add a short body that tells the agent to answer exactly #{token}.
                  The live acceptance harness will drive the product approval gate programmatically once you issue the protected write tool call.
                  Do not stop for conversational confirmation; proceed to the protected write path.
                PROMPT
              )

            ensure!(turn.fetch(:approval_count).positive?, "expected protected skill creation to require approval")
            skill_path = conversation.agent.workspace_root_path.join("skills", skill_name, "SKILL.md")
            ensure!(skill_path.file?, "expected #{skill_path} to exist")
            ensure!(skill_path.read.include?("description: Returns #{token}"), "expected new skill description to be present")

            refreshed = next_turn_skill_descriptions(conversation: conversation)
            ensure!(refreshed.fetch(skill_name) == "Returns #{token}", "expected the new skill to appear on the next top-level turn")

            {
              approval_count: turn.fetch(:approval_count),
              conversation_ids: [conversation.id],
              note: "skill=#{skill_name}",
            }
          end

          def run_modify_agent_local_skill!(agent:, model_ref:, run_index:)
            token = "MODIFY_SKILL_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            conversation = create_live_conversation!(agent: agent, title: "Modify skill #{run_index}")
            skill_path = conversation.agent.workspace_root_path.join("skills/self-mutate/SKILL.md")
            original = skill_path.read

            turn =
              submit_turn!(
                conversation: conversation,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Use the self-mutate skill to update the description field in ../../skills/self-mutate/SKILL.md to exactly "Modified #{token}".
                  Do not create or modify a conversation-local skills/ shadow directory.
                  Preserve the rest of the file.
                  The live acceptance harness will drive the product approval gate programmatically once you issue the protected write tool call.
                  Do not stop for conversational confirmation; proceed to the protected write path.
                PROMPT
              )

            ensure!(turn.fetch(:approval_count).positive?, "expected protected skill edit to require approval")
            ensure!(skill_path.read.include?("description: Modified #{token}"), "expected self-mutate description to change")
            ensure_history_snapshot!(conversation.agent.workspace_root_path, relative_path: "skills/self-mutate/SKILL.md", original_body: original)

            refreshed = next_turn_skill_descriptions(conversation: conversation)
            ensure!(refreshed.fetch("self-mutate") == "Modified #{token}", "expected modified skill description on the next top-level turn")

            {
              approval_count: turn.fetch(:approval_count),
              conversation_ids: [conversation.id],
              note: "self-mutate description updated",
            }
          end

          def run_deny_agents_mutation!(agent:, model_ref:, run_index:)
            token = "AGENTS_DENY_TOKEN_#{run_index}_#{SecureRandom.hex(4)}"
            conversation = create_live_conversation!(agent: agent, title: "Deny AGENTS #{run_index}")
            original = conversation.agent.workspace_root_path.join("AGENTS.md").read

            turn =
              submit_turn!(
                conversation: conversation,
                model_ref: model_ref,
                content: <<~PROMPT,
                  Attempt to append the exact line "#{token}" to ../../AGENTS.md using the normal file tools.
                  Do not glob for AGENTS.md or search for alternate paths.
                  Do not modify any other file.
                PROMPT
              )

            task = find_tool_task(turn.fetch(:agent_node), "write", "edit", "apply_patch", "exec")
            final_content = turn.fetch(:agent_node).body_output.fetch("content", "").to_s
            ensure!(agents_mutation_denied?(task: task, final_content: final_content), "expected AGENTS.md denial text")

            ensure!(conversation.agent.workspace_root_path.join("AGENTS.md").read == original, "AGENTS.md changed despite deny policy")
            ensure!(turn.fetch(:approval_count).zero?, "AGENTS.md denial should not go through approval")

            {
              approval_count: 0,
              conversation_ids: [conversation.id],
              note: "AGENTS.md stayed read-only",
            }
          end

          def create_live_conversation!(agent:, title:, metadata: nil)
            user = create_live_user!
            meta = metadata.is_a?(Hash) ? metadata.deep_stringify_keys : { "agent" => {} }

            Conversation.create!(
              user: user,
              title: title,
              metadata: meta,
              agent: agent,
              permission_mode: "default",
              agent_config_schema_fingerprint: agent.config_schema_fingerprint,
            )
          end

          def create_live_user!
            identity =
              Identity.create!(
                email: "live-acceptance-#{SecureRandom.hex(6)}@example.com",
                password: "Passw0rd",
                password_confirmation: "Passw0rd",
              )

            User.create!(identity: identity, role: :owner)
          end

          def submit_turn!(conversation:, content:, model_ref:)
            prepared = prepare_turn!(conversation: conversation, content: content, model_ref: model_ref)
            complete_prepared_turn!(conversation: conversation, turn_id: prepared.fetch(:turn_id))
          end

          def prepare_turn!(conversation:, content:, model_ref:)
            result = conversation.append_user_message!(content: content, model_ref: model_ref)
            agent_node = result.fetch(:agent_node)
            agent_node.update!(claim_after_at: nil) if agent_node.pending?

            {
              agent_node: agent_node,
              turn_id: agent_node.turn_id,
            }
          end

          def complete_prepared_turn!(conversation:, turn_id:)
            approval_count = 0

            20.times do
              drain_graph!(conversation.root_graph)
              break if turn_terminal?(conversation: conversation, turn_id: turn_id)

              if (approval_target = approval_target_for(conversation: conversation, turn_id: turn_id))
                approval_count += 1
                approve_awaiting_node!(conversation: conversation, target: approval_target)
                drain_graph!(conversation.root_graph)
              end
            end

            ensure!(turn_terminal?(conversation: conversation, turn_id: turn_id), "turn did not reach a terminal state")

            {
              agent_node: final_agent_node_for_turn!(conversation: conversation, turn_id: turn_id),
              approval_count: approval_count,
            }
          end

          def probe_compaction_turn!(conversation:, model_ref:)
            prepared =
              prepare_turn!(
                conversation: conversation,
                model_ref: model_ref,
                content: compaction_prompt_content,
              )
            budget_metadata = turn_budget_metadata_for(agent_node: prepared.fetch(:agent_node))

            prepared.merge(
              context_budget: budget_metadata.fetch("context_budget", {}),
              context_cost: budget_metadata.fetch("context_cost", {}),
            )
          end

          def turn_budget_metadata_for(agent_node:)
            runtime = AgentCore::DAG.runtime_for(node: agent_node)
            execution_context = AgentCore::DAG::ExecutionContextBuilder.build(node: agent_node, runtime: runtime)

            AgentCore::DAG::ContextBudgetManager.new(
              node: agent_node,
              runtime: runtime,
              execution_context: execution_context,
            ).build_prompt(context_nodes: agent_node.graph.context_for_full(agent_node.id)).metadata
          end

          def ordered_compaction_probe_candidates(probe_attempts)
            Array(probe_attempts)
              .filter_map do |attempt|
                probe = attempt.fetch(:probe)
                context_budget = probe.fetch(:context_budget, {})
                next unless context_budget.fetch("budget_action", nil).to_s == "enqueue_compact"

                budget_state = context_budget.fetch("budget_state", nil).to_s
                next unless %w[near_hard_cap forced_fit].include?(budget_state)

                estimated_tokens = probe.dig(:context_cost, "estimated_tokens", "total").to_i
                priority = budget_state == "near_hard_cap" ? 0 : 1

                attempt.merge(priority: priority, estimated_tokens: estimated_tokens)
              end
              .sort_by { |attempt| [attempt.fetch(:priority), attempt.fetch(:estimated_tokens)] }
          end

          def compaction_probe_summary_for(probe_attempts)
            Array(probe_attempts).map do |attempt|
              probe = attempt.fetch(:probe)
              context_budget = probe.fetch(:context_budget, {})
              estimated_tokens = probe.dig(:context_cost, "estimated_tokens", "total")

              [
                "seed=#{attempt.fetch(:max_seed_turns)}",
                "action=#{context_budget.fetch("budget_action", "unknown")}",
                "state=#{context_budget.fetch("budget_state", "unknown")}",
                "estimated=#{estimated_tokens || "unknown"}",
              ].join(",")
            end.join(" ; ")
          end

          def drain_graph!(graph)
            adapter = ActiveJob::Base.queue_adapter
            return drain_graph_via_jobs!(graph, adapter: adapter) if job_driven_drain_supported?(adapter)

            100.times do
              progressed = false

              graph.nodes.active.where(state: DAG::Node::RUNNING).order(:id).pluck(:id).each do |node_id|
                DAG::Runner.run_node!(node_id, enqueue_follow_up: false)
                progressed = true
              end

              claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 20, claimed_by: "live_acceptance")
              if claimed.empty?
                released =
                  graph.leaf_nodes
                    .where(state: DAG::Node::PENDING)
                    .where.not(claim_after_at: nil)
                    .update_all(claim_after_at: nil)
                claimed = DAG::Scheduler.claim_executable_nodes(graph: graph, limit: 20, claimed_by: "live_acceptance") if released.positive?
              end
              claimed.each do |node|
                DAG::Runner.run_node!(node.id, enqueue_follow_up: false)
                progressed = true
              end

              break unless progressed
            end
          end

          def drain_graph_via_jobs!(graph, adapter:)
            100.times do
              release_pending_claims!(graph)
              DAG::TickGraphJob.perform_now(graph.id)

              progressed = perform_enqueued_graph_jobs!(graph: graph, adapter: adapter)
              break unless progressed || graph.nodes.active.where(state: Conversation::IN_FLIGHT_NODE_STATES).exists?
            end
          end

          def job_driven_drain_supported?(adapter)
            adapter.respond_to?(:enqueued_jobs)
          end

          def perform_enqueued_graph_jobs!(graph:, adapter:)
            progressed = false

            loop do
              entry_index = adapter.enqueued_jobs.index { |entry| graph_job_entry?(graph: graph, entry: entry) }
              break unless entry_index

              entry = adapter.enqueued_jobs.delete_at(entry_index)
              args, kwargs = performable_job_arguments(entry)
              entry.fetch(:job).perform_now(*args, **kwargs)
              progressed = true
            end

            progressed
          end

          def graph_job_entry?(graph:, entry:)
            job_class = entry[:job]
            args = Array(entry[:args])

            case job_class.to_s
            when "DAG::TickGraphJob"
              args.first.to_s == graph.id.to_s
            when "DAG::ExecuteNodeJob"
              node_id = args.first
              graph.nodes.where(id: node_id).exists?
            else
              false
            end
          end

          def performable_job_arguments(entry)
            args = Array(entry[:args]).deep_dup
            kwargs = {}
            return [args, kwargs] unless args.last.is_a?(Hash)

            marker_keys = [:_aj_ruby2_keywords, "_aj_ruby2_keywords"]
            marker_key = marker_keys.find { |key| args.last.key?(key) }
            return [args, kwargs] unless marker_key

            raw_kwargs = args.pop.deep_dup
            keyword_names = Array(raw_kwargs.delete(marker_key)).map(&:to_s)
            kwargs =
              keyword_names.each_with_object({}) do |name, out|
                value =
                  if raw_kwargs.key?(name)
                    raw_kwargs[name]
                  else
                    raw_kwargs[name.to_sym]
                  end
                out[name.to_sym] = value
              end

            [args, kwargs]
          end

          def release_pending_claims!(graph)
            graph.leaf_nodes
              .where(state: DAG::Node::PENDING)
              .where.not(claim_after_at: nil)
              .update_all(claim_after_at: nil)
          end

          def turn_tasks(agent_node)
            agent_node.graph.nodes.active.where(turn_id: agent_node.turn_id, node_type: Messages::Task.node_type_key).order(:id).to_a
          end

          def turn_terminal?(conversation:, turn_id:)
            active_states = conversation.root_graph.nodes.active.where(turn_id: turn_id, state: Conversation::IN_FLIGHT_NODE_STATES).exists?
            return false if active_states

            !conversation.turn_internal_tasks.nonterminal.where(turn_id: turn_id).exists?
          end

          def approval_target_for(conversation:, turn_id:)
            draft =
              conversation.run_drafts.where(status: "awaiting_approval").order(:created_at).find do |candidate|
                node_id = candidate.trigger_snapshot["dag_node_id"].to_s
                next false if node_id.blank?

                conversation.root_graph.nodes.where(id: node_id, turn_id: turn_id).exists?
              end

            if draft.present?
              return {
                kind: :parked_agent_node,
                node_id: draft.trigger_snapshot.fetch("dag_node_id").to_s,
              }
            end

            approval_node =
              conversation.root_graph.nodes.active
                .where(turn_id: turn_id, state: DAG::Node::AWAITING_APPROVAL)
                .order(:id)
                .first
            return nil unless approval_node.present?

            {
              kind: :dag_node,
              node_id: approval_node.id,
            }
          end

          def approve_awaiting_node!(conversation:, target:)
            node_id = target.fetch(:node_id)

            case target.fetch(:kind)
            when :parked_agent_node
              conversation.approve_parked_agent_node!(node_id: node_id, approved_by: DEFAULT_APPROVER)
            when :dag_node
              node = conversation.root_graph.nodes.active.find(node_id)
              node.approve!(metadata: { "approved_by" => DEFAULT_APPROVER, "approved_at" => Time.current.iso8601 })
            else
              raise ArgumentError, "unknown approval target: #{target.inspect}"
            end
          end

          def require_tool_task!(agent_node, *logical_names)
            names = logical_names.map(&:to_s)
            task = find_tool_task(agent_node, *names)
            ensure!(task.present?, "expected a task for #{names.join(", ")}")
            task
          end

          def find_tool_task(agent_node, *logical_names)
            names = logical_names.map(&:to_s)

            turn_tasks(agent_node).find do |node|
              names.include?(
                node.body_input["logical_tool_name"].presence ||
                  node.body_input["name"].presence ||
                  node.body_input["requested_name"].presence,
              )
            end
          end

          def task_arguments(task)
            value = task.body_input["arguments"]
            value.is_a?(Hash) ? value.deep_stringify_keys : {}
          end

          def task_succeeded?(task)
            result = AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result"))
            result.error? == false
          end

          def parsed_tool_payload(task)
            result = AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result"))
            JSON.parse(result.text)
          rescue JSON::ParserError => e
            raise ScenarioFailure, "expected JSON tool payload for #{task.id}: #{e.message}"
          end

          def memory_store_scope_for(task)
            arguments = task_arguments(task)
            return arguments.fetch("scope") if arguments["scope"].present?

            parsed_tool_payload(task).dig("document", "scope").to_s
          end

          def require_memory_lookup!(agent_node, token: nil, expected_scope:, allow_store_fallback: false)
            task =
              turn_tasks(agent_node).find do |node|
                logical_name =
                  node.body_input["logical_tool_name"].presence ||
                    node.body_input["name"].presence ||
                    node.body_input["requested_name"].presence
                %w[memory_get memory_search].include?(logical_name)
              end

            if task.blank? && allow_store_fallback
              task = find_tool_task(agent_node, "memory_store")
            end

            ensure!(task.present?, "expected a memory_get or memory_search task")

            arguments = task_arguments(task)
            if arguments.key?("scope")
              assert_equal expected_scope, arguments.fetch("scope")
            elsif arguments.key?("scopes")
              ensure!(Array(arguments.fetch("scopes")).map(&:to_s).include?(expected_scope), "expected scopes to include #{expected_scope}")
            end

            payload = parsed_tool_payload(task)
            if token.present?
              text = payload.dig("document", "body").to_s
              text = payload.fetch("matches", []).map { |match| match["snippet"].to_s }.join("\n") if text.empty?
              ensure!(text.include?(token), "expected memory lookup payload to include #{token}")
            end

            payload
          end

          def ensure_history_snapshot!(root_path, relative_path:, original_body:)
            snapshots = Dir.glob(root_path.join(".history", "**", *relative_path.split("/")).to_s).sort
            ensure!(snapshots.any?, "expected a history snapshot for #{relative_path}")
            ensure!(File.read(snapshots.last) == original_body, "expected latest history snapshot to preserve the previous #{relative_path} content")
          end

          def agents_mutation_refusal?(content)
            text = content.to_s
            return false if text.empty?

            mentions_target = text.include?("AGENTS.md")
            signals_refusal = text.match?(/\b(read-only|cannot|can't|can’t|unable|won't|won’t|refuse|refusing|protected)\b/i)
            mentions_target && signals_refusal
          end

          def agents_mutation_denied?(task:, final_content:)
            return agents_mutation_refusal?(final_content) unless task.present?

            result = AgentCore::Resources::Tools::ToolResult.from_h(task.body_output.fetch("result"))
            return false unless result.error?

            path = task_arguments(task).fetch("path", "").to_s
            text = [result.text, final_content].join("\n")
            mentions_target = text.include?("AGENTS.md") || path.end_with?("AGENTS.md")
            signals_refusal =
              text.match?(
                /\b(read-only|cannot|can't|can’t|unable|won't|won’t|refuse|refusing|protected|denied by policy|protected_agent_root_read_only)\b/i,
              )

            mentions_target && signals_refusal
          end

          def final_agent_node_for_turn!(conversation:, turn_id:)
            node =
              conversation.root_graph.nodes.active
                .where(turn_id: turn_id, node_type: [Messages::AgentMessage.node_type_key, Messages::CharacterMessage.node_type_key])
                .order(:id)
                .last

            ensure!(node.present?, "expected a final agent node for turn #{turn_id}")
            node
          end

          def next_turn_skill_descriptions(conversation:)
            node = conversation.append_user_message!(content: "Refresh skills inventory").fetch(:agent_node)
            runtime =
              Cybros::AgentRuntimeResolver.runtime_for(
                node: node,
                provider: Struct.new(:name).new("live_acceptance_stub"),
                base_tool_policy: AgentCore::Resources::Tools::Policy::AllowAll.new,
                instrumenter: AgentCore::Observability::NullInstrumenter.new,
              )

            ensure!(runtime.skills_store.present?, "expected a live skills store on the next top-level turn")
            runtime.skills_store.list_skills.index_by(&:name).transform_values(&:description)
          end

          def seed_directory_noise!(workspace_root)
            40.times do |index|
              nested = workspace_root.join("scratch", "noise-#{index}", "deep-#{index % 5}")
              FileUtils.mkdir_p(nested)
              4.times do |file_index|
                nested.join("note-#{file_index}.txt").write("noise #{index}-#{file_index}\n")
              end
            end
          end

          def compaction_seed_turn_candidates
            [12, 13, 14, 15, 16, 17, 18]
          end

          def seed_compaction_history!(conversation:, model_ref:, max_seed_turns: nil)
            graph = conversation.dag_graph
            lane = conversation.chat_lane
            token_counter = token_counter_for(model_ref: model_ref)
            soft_limit_tokens = effective_context_soft_limit_tokens_for(model_ref: model_ref) || effective_context_window_tokens_for(model_ref: model_ref)
            hard_limit_tokens = effective_context_window_tokens_for(model_ref: model_ref)
            target_tokens = [(soft_limit_tokens * 0.8).floor, 1].max
            chunk =
              content_for_minimum_tokens(
                token_counter: token_counter,
                minimum_tokens: compaction_seed_chunk_tokens_for(model_ref: model_ref),
              )
            sequence_parent = nil
            turn_count = max_seed_turns.to_i.positive? ? max_seed_turns.to_i : 16

            turn_count.times do |index|
              marker = "COMPACTION_MARKER_#{index + 1}"
              created =
                create_finished_turn!(
                  graph: graph,
                  lane: lane,
                  user_content: "#{marker}\n#{chunk}",
                  agent_content: "#{marker} reply\n#{chunk}",
                  sequence_parent: sequence_parent,
                )
              sequence_parent = created.fetch(:agent_node)

              projected_tokens =
                projected_context_tokens_for(
                  conversation: conversation,
                  content: compaction_prompt_content,
                  model_ref: model_ref,
                )
              break if projected_tokens > target_tokens && projected_tokens < soft_limit_tokens && projected_tokens < hard_limit_tokens
            end
          end

          def token_counter_for(model_ref:)
            provider_key, model_key = model_ref.to_s.split("/", 2)
            model_spec = Cybros::LLM::Catalog.effective.model(provider_key, model_key)

            AgentCore::Resources::TokenCounter::Estimator.new(
              token_estimator: Cybros::TokenEstimation.estimator(tokenizer_root_path: Cybros::TokenEstimation.tokenizer_root, strict: false),
              model_hint: model_spec.fetch("tokenizer_hint", model_spec.fetch("api_model")).to_s,
            )
          end

          def effective_context_window_tokens_for(model_ref:)
            provider_key, model_key = model_ref.to_s.split("/", 2)
            model_spec = Cybros::LLM::Catalog.effective.model(provider_key, model_key)
            provider_spec = Cybros::LLM::Catalog.effective.provider(provider_key)
            provider_limit = provider_spec.fetch("context_window_tokens", 0).to_i
            model_limit = model_spec.fetch("context_window_tokens").to_i
            provider_limit.positive? ? [provider_limit, model_limit].min : model_limit
          end

          def compaction_seed_chunk_tokens_for(model_ref:)
            budget = effective_context_window_tokens_for(model_ref: model_ref)
            [(budget * 0.02).ceil, 1].max
          end

          def effective_context_soft_limit_tokens_for(model_ref:)
            budget = effective_context_window_tokens_for(model_ref: model_ref)
            ratio = effective_context_soft_limit_ratio_for(model_ref: model_ref)
            return (budget * ratio).floor if ratio.present?

            provider_key, model_key = model_ref.to_s.split("/", 2)
            model_spec = Cybros::LLM::Catalog.effective.model(provider_key, model_key)
            value = model_spec.fetch("context_soft_limit_tokens", nil).to_i
            value.positive? ? value : nil
          end

          def effective_context_soft_limit_ratio_for(model_ref:)
            provider_key, model_key = model_ref.to_s.split("/", 2)
            model_spec = Cybros::LLM::Catalog.effective.model(provider_key, model_key)

            ratio = model_spec.fetch("context_soft_limit_ratio", nil)
            return ratio.to_f if ratio.present?

            soft_limit_tokens = model_spec.fetch("context_soft_limit_tokens", nil).to_i
            return nil unless soft_limit_tokens.positive?

            soft_limit_tokens.to_f / effective_context_window_tokens_for(model_ref: model_ref)
          end

          def projected_context_tokens_for(conversation:, content:, model_ref:)
            context_nodes =
              conversation.chat_lane.transcript_recent_turns(limit_turns: 1000, mode: :full) + [
                synthetic_user_node(conversation: conversation, content: content),
              ]
            adapted = AgentCore::DAG::ContextAdapter.new(context_nodes: context_nodes).call
            token_counter = token_counter_for(model_ref: model_ref)

            token_counter.count_text(adapted.system_prompt.to_s) + token_counter.count_messages(adapted.messages)
          end

          def synthetic_user_node(conversation:, content:)
            {
              "node_id" => "synthetic-user",
              "turn_id" => "synthetic-turn",
              "lane_id" => conversation.chat_lane.id,
              "node_type" => Messages::UserMessage.node_type_key,
              "state" => DAG::Node::FINISHED,
              "payload" => {
                "input" => { "content" => content },
                "output" => {},
                "output_preview" => {},
              },
              "metadata" => {},
            }
          end

          def compaction_prompt_content
            <<~PROMPT
              If the runtime exposes `compact_context`, call it before you answer with these exact arguments:
              {"reason":"soft_limit_reached"}

              After `compact_context` finishes, reply exactly:
              COMPACTION_DONE
            PROMPT
          end

          def content_for_minimum_tokens(token_counter:, minimum_tokens:)
            content = +"history context detail "
            segment_index = 0

            while token_counter.count_text(content) < minimum_tokens
              segment_index += 1
              content << "segment #{segment_index} retains prior reasoning context for compaction durability. "
            end

            content
          end

          def create_finished_turn!(graph:, lane:, user_content:, agent_content:, sequence_parent:)
            turn_id = ActiveRecord::Base.lease_connection.select_value("select uuidv7()")
            created = nil

            graph.mutate!(turn_id: turn_id) do |mutations|
              user_node =
                mutations.create_node(
                  node_type: Messages::UserMessage.node_type_key,
                  state: DAG::Node::FINISHED,
                  lane_id: lane.id,
                  content: user_content,
                  metadata: { "fragments" => [user_content] },
                )
              agent_node =
                mutations.create_node(
                  node_type: Messages::AgentMessage.node_type_key,
                  state: DAG::Node::FINISHED,
                  lane_id: lane.id,
                  body_output: { "content" => agent_content },
                  metadata: {},
                )

              mutations.create_edge(from_node: sequence_parent, to_node: user_node, edge_type: DAG::Edge::SEQUENCE) if sequence_parent
              mutations.create_edge(from_node: user_node, to_node: agent_node, edge_type: DAG::Edge::SEQUENCE)

              created = { user_node: user_node, agent_node: agent_node }
            end

            created
          end

          def say(message)
            io.puts(message)
          end

          def ensure!(condition, message)
            raise ScenarioFailure, message unless condition
          end

          def assert_equal(expected, actual)
            ensure!(expected == actual, "expected #{expected.inspect}, got #{actual.inspect}")
          end

          def assert_includes(haystack, needle)
            ensure!(haystack.to_s.include?(needle.to_s), "expected #{haystack.inspect} to include #{needle.inspect}")
          end
      end
    end
  end
end

unless ENV["CYBROS_LIVE_ACCEPTANCE_NO_AUTORUN"] == "1"
  options = Cybros::LiveAcceptance::AgentRootWorkspace::Runner.parse_options(ARGV)
  Cybros::LiveAcceptance::AgentRootWorkspace::Runner.new(**options).run!
end
