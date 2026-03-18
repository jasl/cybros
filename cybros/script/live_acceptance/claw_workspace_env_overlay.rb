require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "socket"
require Rails.root.join("test/support/bundled_claw_runtime_server")

live_acceptance_autorun = ENV["CYBROS_LIVE_ACCEPTANCE_NO_AUTORUN"]
ENV["CYBROS_LIVE_ACCEPTANCE_NO_AUTORUN"] = "1"
require_relative "agent_root_workspace"

if live_acceptance_autorun.nil?
  ENV.delete("CYBROS_LIVE_ACCEPTANCE_NO_AUTORUN")
else
  ENV["CYBROS_LIVE_ACCEPTANCE_NO_AUTORUN"] = live_acceptance_autorun
end

module Cybros
  module LiveAcceptance
    module ClawWorkspaceEnvOverlay
      ScenarioFailure = AgentRootWorkspace::ScenarioFailure

      class Runner < AgentRootWorkspace::Runner
        REPORT_SLUG = "claw_workspace_env_overlay".freeze
        SCENARIO_ID = "rbenv_shell_resolution".freeze
        REPORT_PATH = Rails.root.join("docs/reports/2026-03-18-claw-workspace-env-overlay-proof.md")
        SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin".freeze
        PROBE_KEYS = {
          "RUBY_PATH" => "ruby_path",
          "RUBY_VERSION" => "ruby_version",
          "BUNDLE_PATH" => "bundle_path",
          "BUNDLE_VERSION" => "bundle_version",
          "RBENV_ROOT" => "rbenv_root",
          "BUNDLE_GEMFILE" => "bundle_gemfile",
          "RUBYOPT" => "rubyopt",
        }.freeze
        PROBE_COMMAND = <<~'SH'.strip.freeze
          ruby_path="$(command -v ruby 2>/dev/null || true)"
          bundle_path="$(command -v bundle 2>/dev/null || true)"
          ruby_version="$(ruby -v 2>&1 || true)"
          bundle_version="$(bundle -v 2>&1 || true)"
          printf 'RUBY_PATH=%s\n' "$ruby_path"
          printf 'RUBY_VERSION=%s\n' "$ruby_version"
          printf 'BUNDLE_PATH=%s\n' "$bundle_path"
          printf 'BUNDLE_VERSION=%s\n' "$bundle_version"
          printf 'RBENV_ROOT=%s\n' "${RBENV_ROOT:-}"
          printf 'BUNDLE_GEMFILE=%s\n' "${BUNDLE_GEMFILE:-}"
          printf 'RUBYOPT=%s\n' "${RUBYOPT:-}"
        SH
        ZSH_PROBE_BEGIN = "__CYBROS_ZSH_PROBE_BEGIN__".freeze
        ZSH_PROBE_END = "__CYBROS_ZSH_PROBE_END__".freeze
        BUNDLED_CLAW_BOOTSTRAP_BEARER = "secret://bundled-claw:live-acceptance".freeze
        BUNDLED_CLAW_BOOTSTRAP_FINGERPRINT = "deployment:bundled-claw:live-acceptance".freeze
        BUNDLED_CLAW_BOOTSTRAP_ENVIRONMENT_VARIABLES = %w[
          CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL
          CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER
          CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT
        ].freeze
        ZSH_PROBE_COMMAND = <<~SH.freeze
          set -e
          command -v rbenv >/dev/null
          printf '#{ZSH_PROBE_BEGIN}\\n'
          printf 'RBENV_ROOT=%s\\n' "$(rbenv root)"
          printf 'PATH_VALUE=%s\\n' "$PATH"
          printf 'RUBY_PATH=%s\\n' "$(command -v ruby)"
          printf 'RUBY_VERSION=%s\\n' "$(ruby -v)"
          printf 'BUNDLE_PATH=%s\\n' "$(command -v bundle 2>/dev/null || true)"
          printf 'BUNDLE_VERSION=%s\\n' "$(bundle -v 2>/dev/null || true)"
          printf '#{ZSH_PROBE_END}\\n'
        SH

        def self.parse_options(argv)
          options = {
            model_ref: ENV["CLAW_WORKSPACE_ENV_OVERLAY_MODEL_REF"].to_s.strip.presence,
            report_path: ENV["CLAW_WORKSPACE_ENV_OVERLAY_REPORT_PATH"].to_s.strip.presence,
            workspace_root_base: ENV["CLAW_WORKSPACE_ENV_OVERLAY_BASE"].to_s.strip.presence,
            keep_workspace_root: ENV["CLAW_WORKSPACE_ENV_OVERLAY_KEEP_ROOT"].to_s.strip != "0",
          }

          OptionParser.new do |parser|
            parser.banner = "Usage: bin/rails runner script/live_acceptance/claw_workspace_env_overlay.rb [options]"

            parser.on("--model-ref MODEL_REF", "Model ref for the live run") { |value| options[:model_ref] = value }
            parser.on("--report-path PATH", "Proof markdown output path") { |value| options[:report_path] = value }
            parser.on("--workspace-root-base PATH", "Temporary agent workspace root base") { |value| options[:workspace_root_base] = value }
            parser.on("--cleanup", "Delete the temporary agent workspace root after the run") { options[:keep_workspace_root] = false }
            parser.on("--keep-workspace-root", "Keep the temporary agent workspace root after the run") { options[:keep_workspace_root] = true }
          end.parse!(Array(argv))

          options
        end

        def initialize(model_ref: nil, report_path: REPORT_PATH, workspace_root_base: nil, keep_workspace_root: true, io: $stdout)
          super(
            model_ref: model_ref,
            report_path: report_path || REPORT_PATH,
            workspace_root_base: workspace_root_base,
            keep_workspace_root: keep_workspace_root,
            runs_per_scenario: 1,
            io: io,
          )
        end

        def report_slug = REPORT_SLUG

        def scenario_id = SCENARIO_ID

        def run!
          ensure_live_provider_ready!
          zsh_probe = interactive_zsh_probe!
          simulated_process_env = simulated_process_env_for(zsh_probe: zsh_probe)

          started_at = Time.current.utc
          original_queue_adapter = ActiveJob::Base.queue_adapter
          original_agent_workspace_root = runtime_setting_record.agent_workspace_root

          ActiveJob::Base.queue_adapter = :test
          runtime_setting_record.update!(agent_workspace_root: workspace_root_base.to_s)
          FileUtils.mkdir_p(workspace_root_base)

          with_bundled_claw_bootstrap_env do
            with_callback_base_url do
              agent = ::Agents::BootstrapBundledDefaultService.ensure_agent!
              reset_agent_root!(agent)
              model_ref = resolved_model_ref

              say("Running claw workspace env overlay live acceptance")
              say("Model ref: #{model_ref}")
              say("Workspace root base: #{workspace_root_base}")
              say("Report path: #{report_path}")

              scenario =
                with_process_env(simulated_process_env) do
                  run_rbenv_shell_resolution!(
                    agent: agent,
                    model_ref: model_ref,
                    zsh_probe: zsh_probe,
                    simulated_process_env: simulated_process_env,
                  )
                end

              finished_at = Time.current.utc
              markdown =
                proof_markdown(
                  started_at: started_at,
                  finished_at: finished_at,
                  model_ref: model_ref,
                  environment_label: "#{Rails.env} @ #{Socket.gethostname}",
                  scenario: scenario,
                )

              FileUtils.mkdir_p(report_path.dirname)
              report_path.write(markdown)
              say("Proof written to #{report_path}")
              true
            end
          end
        ensure
          ActiveJob::Base.queue_adapter = original_queue_adapter if original_queue_adapter
          runtime_setting_record.update!(agent_workspace_root: original_agent_workspace_root) if original_agent_workspace_root.present?
        end

        def proof_markdown(started_at:, finished_at:, model_ref:, environment_label:, scenario:)
          lines = []
          lines << "# Claw Workspace Env Overlay Proof"
          lines << ""
          lines << "- Date: #{finished_at.to_date.iso8601}"
          lines << "- Started at (UTC): #{started_at.utc.iso8601}"
          lines << "- Finished at (UTC): #{finished_at.utc.iso8601}"
          lines << "- Model ref: #{model_ref}"
          lines << "- Environment: #{environment_label}"
          lines << "- Workspace root base: `#{workspace_root_base}`"
          lines << "- Scenario id: `#{scenario.fetch(:id)}`"
          lines << "- Lane env path: `#{scenario.fetch(:lane_env_path)}`"
          lines << "- Root env path: `#{scenario.fetch(:root_env_path)}`"
          lines << "- Approval count: #{scenario.fetch(:approval_count, 0)}"
          lines << "- Conversation ids: #{Array(scenario.fetch(:conversation_ids, [])).join(", ")}"
          lines << ""
          lines << "## Expected interactive zsh target"
          lines << ""
          lines << probe_markdown_table(scenario.fetch(:expected))
          lines << ""
          lines << "## Baseline"
          lines << ""
          lines << probe_markdown_table(scenario.fetch(:baseline))
          lines << ""
          lines << "## Lane-local fix"
          lines << ""
          lines << probe_markdown_table(scenario.fetch(:lane_fix))
          lines << ""
          lines << "## Promoted root fix"
          lines << ""
          lines << probe_markdown_table(scenario.fetch(:root_fix))
          lines << ""
          lines << "## Simulated process env"
          lines << ""
          lines << "```"
          Array(scenario.fetch(:simulated_process_env, {})).sort_by { |key, _| key.to_s }.each do |key, value|
            lines << "#{key}=#{value}"
          end
          lines << "```"

          lines.join("\n") + "\n"
        end

        private

          def resolved_model_ref
            @resolved_model_ref ||=
              begin
                requested = @model_ref.to_s.strip
                return requested if requested.present? && model_ref_usable?(requested) && !requested.start_with?("dev/")

                candidates = [
                  "openrouter/openai-gpt-5.4-live-acceptance",
                  "openrouter/openai-gpt-5.4",
                  "codex_subscription/gpt-5.4",
                  "openai/gpt-5.4",
                ]

                candidates.each do |candidate|
                  return candidate if model_ref_usable?(candidate)
                end

                usable =
                  Cybros::AgentRuntimeResolver.usable_model_options.find do |option|
                    !option.fetch(:model_ref).to_s.start_with?("dev/")
                  end
                return usable.fetch(:model_ref) if usable.present?

                raise ScenarioFailure, "No usable live model ref found. Configure a real provider or pass --model-ref."
              end
          end

          def run_rbenv_shell_resolution!(agent:, model_ref:, zsh_probe:, simulated_process_env:)
            primary = create_live_conversation!(agent: agent, title: "Claw env overlay lane proof")
            Conversations::WorkspaceInitializer.initialize!(conversation: primary)

            lane_env_relative_path = ".lanes/#{primary.chat_lane.id}/.env.agent"
            root_env_relative_path = "../../.env.agent"
            payload =
              scenario_payload_for(
                lane_env_path: lane_env_relative_path,
                root_env_path: root_env_relative_path,
                zsh_probe: zsh_probe,
                simulated_process_env: simulated_process_env,
              )

            lane_env_file = actual_lane_workspace_root_path(primary).join(".env.agent")
            root_env_file = actual_agent_root_path.join(".env.agent")
            ensure!(!lane_env_file.exist?, "expected no pre-existing lane env file at #{lane_env_file}")
            ensure!(!root_env_file.exist?, "expected no pre-existing root env file at #{root_env_file}")

            baseline_turn =
              submit_turn!(
                conversation: primary,
                model_ref: model_ref,
                content: exec_prompt_for(command: payload.fetch(:probe_command)),
              )
            baseline_exec = require_successful_tool_task!(baseline_turn.fetch(:agent_node), "exec")
            baseline = observe_exec_probe!(baseline_exec)
            ensure_baseline_diverges!(
              observed: baseline,
              expected: payload.fetch(:expected),
              simulated_process_env: payload.fetch(:simulated_process_env),
            )
            ensure!(tool_result_for(baseline_exec).metadata.fetch("env_files_loaded", []).empty?, "baseline exec unexpectedly loaded env overlay files")

            lane_fix_turn =
              submit_turn!(
                conversation: primary,
                model_ref: model_ref,
                content: write_and_exec_prompt_for(
                  env_path: payload.fetch(:lane_env_path),
                  env_body: payload.fetch(:lane_env_body),
                  command: payload.fetch(:probe_command),
                ),
              )
            ensure!(lane_fix_turn.fetch(:approval_count) >= 1, "expected lane env write to require approval")

            lane_write = require_successful_tool_task!(lane_fix_turn.fetch(:agent_node), "write")
            assert_equal payload.fetch(:lane_env_path), task_arguments(lane_write).fetch("path")
            assert_equal payload.fetch(:lane_env_body), task_arguments(lane_write).fetch("content")
            assert_equal payload.fetch(:lane_env_body), lane_env_file.read

            lane_exec = require_successful_tool_task!(lane_fix_turn.fetch(:agent_node), "exec")
            lane_fix = observe_exec_probe!(lane_exec)
            ensure_probe_matches!(observed: lane_fix, expected: payload.fetch(:expected))
            assert_includes tool_result_for(lane_exec).metadata.fetch("env_files_loaded", []), comparable_path_for(lane_env_file)

            root_promote_turn =
              submit_turn!(
                conversation: primary,
                model_ref: model_ref,
                content: write_prompt_for(
                  env_path: payload.fetch(:root_env_path),
                  env_body: payload.fetch(:root_env_body),
                  phase_label: "promoted root fix",
                ),
              )
            ensure!(root_promote_turn.fetch(:approval_count) >= 1, "expected root env write to require approval")

            root_write = require_successful_tool_task!(root_promote_turn.fetch(:agent_node), "write")
            assert_equal payload.fetch(:root_env_path), task_arguments(root_write).fetch("path")
            assert_equal payload.fetch(:root_env_body), task_arguments(root_write).fetch("content")
            assert_equal payload.fetch(:root_env_body), root_env_file.read

            inherited = create_live_conversation!(agent: agent, title: "Claw env overlay root inheritance proof")
            Conversations::WorkspaceInitializer.initialize!(conversation: inherited)
            inherited_lane_env = actual_lane_workspace_root_path(inherited).join(".env.agent")
            ensure!(!inherited_lane_env.exist?, "expected fresh lane to start without its own env override")

            root_fix_turn =
              submit_turn!(
                conversation: inherited,
                model_ref: model_ref,
                content: exec_prompt_for(command: payload.fetch(:probe_command)),
              )
            root_exec = require_successful_tool_task!(root_fix_turn.fetch(:agent_node), "exec")
            root_fix = observe_exec_probe!(root_exec)
            ensure_probe_matches!(observed: root_fix, expected: payload.fetch(:expected))
            assert_includes tool_result_for(root_exec).metadata.fetch("env_files_loaded", []), comparable_path_for(root_env_file)

            {
              id: SCENARIO_ID,
              approval_count: baseline_turn.fetch(:approval_count) + lane_fix_turn.fetch(:approval_count) + root_promote_turn.fetch(:approval_count) + root_fix_turn.fetch(:approval_count),
              conversation_ids: [primary.id, inherited.id],
              lane_env_path: payload.fetch(:lane_env_path),
              root_env_path: payload.fetch(:root_env_path),
              baseline: baseline,
              lane_fix: lane_fix,
              root_fix: root_fix,
              expected: payload.fetch(:expected),
              simulated_process_env: payload.fetch(:simulated_process_env),
            }
          end

          def interactive_zsh_probe!
            stdout, stderr, status = Open3.capture3("/bin/zsh", "-lic", ZSH_PROBE_COMMAND)
            unless status.success?
              raise ScenarioFailure, "interactive zsh probe failed: #{stderr.presence || stdout.presence || "unknown error"}"
            end

            lines = stdout.lines.map(&:chomp)
            begin_index = lines.index(ZSH_PROBE_BEGIN)
            end_index = lines.index(ZSH_PROBE_END)
            ensure!(begin_index.present? && end_index.present? && end_index > begin_index, "interactive zsh probe markers were missing")

            parsed =
              lines[(begin_index + 1)...end_index].each_with_object({}) do |line, memo|
                key, value = line.split("=", 2)
                memo[key.to_s.downcase] = value.to_s
              end

            ensure!(parsed["rbenv_root"].present?, "interactive zsh probe did not resolve RBENV_ROOT")
            ensure!(parsed["ruby_path"].include?(parsed.fetch("rbenv_root")), "interactive zsh ruby is not resolved through rbenv")
            ensure!(parsed["path_value"].include?("#{parsed.fetch("rbenv_root")}/shims"), "interactive zsh PATH is missing rbenv shims")

            {
              "rbenv_root" => parsed.fetch("rbenv_root"),
              "path_value" => parsed.fetch("path_value"),
              "ruby_path" => parsed.fetch("ruby_path"),
              "ruby_version" => parsed.fetch("ruby_version"),
              "bundle_path" => parsed.fetch("bundle_path"),
              "bundle_version" => parsed.fetch("bundle_version"),
            }
          end

          def simulated_process_env_for(zsh_probe:)
            {
              "PATH" => SYSTEM_PATH,
              "RBENV_ROOT" => nil,
              "BUNDLE_GEMFILE" => "/tmp/cybros-live-acceptance-poisoned/Gemfile",
              "RUBYOPT" => "-W0",
              "HOME" => ENV["HOME"].to_s,
            }.compact
          end

          def scenario_payload_for(lane_env_path:, root_env_path:, zsh_probe:, simulated_process_env:)
            env_body = <<~ENV
              unset BUNDLE_GEMFILE
              unset RUBYOPT
              RBENV_ROOT=#{zsh_probe.fetch("rbenv_root")}
              PATH=#{zsh_probe.fetch("path_value")}
            ENV

            {
              scenario_id: SCENARIO_ID,
              lane_env_path: lane_env_path,
              root_env_path: root_env_path,
              lane_env_body: env_body,
              root_env_body: env_body,
              probe_command: PROBE_COMMAND,
              expected: {
                "ruby_path" => zsh_probe.fetch("ruby_path"),
                "ruby_version" => zsh_probe.fetch("ruby_version"),
                "bundle_path" => zsh_probe.fetch("bundle_path"),
                "bundle_version" => zsh_probe.fetch("bundle_version"),
                "rbenv_root" => zsh_probe.fetch("rbenv_root"),
                "bundle_gemfile" => "",
                "rubyopt" => "",
              },
              simulated_process_env: simulated_process_env,
            }
          end

          def exec_prompt_for(command:)
            <<~PROMPT
              Use the `exec` tool exactly once with these exact arguments JSON:
              #{JSON.generate({ "command" => command })}

              Do not write, edit, or patch any files in this turn.
            PROMPT
          end

          def write_and_exec_prompt_for(env_path:, env_body:, command:)
            <<~PROMPT
              First use the `write` tool exactly once with these exact arguments JSON:
              #{JSON.generate({ "path" => env_path, "content" => env_body })}

              After that write succeeds and any approval is granted, use the `exec` tool exactly once with these exact arguments JSON:
              #{JSON.generate({ "command" => command })}

              Do not use any other tool names in this turn.
            PROMPT
          end

          def write_prompt_for(env_path:, env_body:, phase_label:)
            <<~PROMPT
              Use the `write` tool exactly once to create the #{phase_label} file with these exact arguments JSON:
              #{JSON.generate({ "path" => env_path, "content" => env_body })}

              Do not run shell commands in this turn.
            PROMPT
          end

          def require_successful_tool_task!(agent_node, *logical_names)
            names = logical_names.map(&:to_s)
            task =
              turn_tasks(agent_node).find do |node|
                logical_name =
                  node.body_input["logical_tool_name"].presence ||
                    node.body_input["name"].presence ||
                    node.body_input["requested_name"].presence

                names.include?(logical_name) && task_succeeded?(node)
              end

            ensure!(task.present?, "expected a successful task for #{names.join(", ")}")
            task
          end

          def observe_exec_probe!(task)
            payload = parsed_tool_payload(task)
            ensure!(payload.fetch("status") == "ok", "expected exec probe to complete successfully")

            parse_probe_stdout(payload.fetch("stdout")).merge(
              "exit_code" => payload.fetch("exit_code"),
              "env_files_loaded" => tool_result_for(task).metadata.fetch("env_files_loaded", []),
            )
          end

          def parse_probe_stdout(stdout)
            stdout.to_s.each_line.with_object({}) do |line, memo|
              key, value = line.to_s.chomp.split("=", 2)
              normalized_key = PROBE_KEYS[key.to_s]
              next if normalized_key.nil?

              memo[normalized_key] = value.to_s
            end
          end

          def ensure_baseline_diverges!(observed:, expected:, simulated_process_env:)
            ensure!(observed.fetch("ruby_path", "") != expected.fetch("ruby_path"), "baseline ruby path unexpectedly already matched the interactive rbenv target")
            assert_equal simulated_process_env.fetch("BUNDLE_GEMFILE"), observed.fetch("bundle_gemfile")
            assert_equal simulated_process_env.fetch("RUBYOPT"), observed.fetch("rubyopt")
          end

          def ensure_probe_matches!(observed:, expected:)
            assert_equal expected.fetch("ruby_path"), observed.fetch("ruby_path")
            assert_equal expected.fetch("ruby_version"), observed.fetch("ruby_version")
            assert_equal expected.fetch("rbenv_root"), observed.fetch("rbenv_root")
            assert_equal expected.fetch("bundle_gemfile"), observed.fetch("bundle_gemfile")
            assert_equal expected.fetch("rubyopt"), observed.fetch("rubyopt")
            if expected.fetch("bundle_path", "").present?
              assert_equal expected.fetch("bundle_path"), observed.fetch("bundle_path")
            end
            if expected.fetch("bundle_version", "").present?
              assert_equal expected.fetch("bundle_version"), observed.fetch("bundle_version")
            end
          end

          def probe_markdown_table(probe)
            rows = []
            rows << "| Field | Value |"
            rows << "| --- | --- |"
            Array(probe).sort_by { |key, _| key.to_s }.each do |key, value|
              rows << "| #{key} | `#{value.to_s.gsub("`", "\\`")}` |"
            end
            rows.join("\n")
          end

          def with_process_env(overrides)
            prior = {}
            overrides.each do |key, value|
              prior[key] = ENV[key]
              if value.nil?
                ENV.delete(key)
              else
                ENV[key] = value.to_s
              end
            end

            yield
          ensure
            prior.each do |key, value|
              if value.nil?
                ENV.delete(key)
              else
                ENV[key] = value
              end
            end
          end

          def actual_agent_root_path
            workspace_root_base.join("bundled", "claw")
          end

          def actual_lane_workspace_root_path(conversation)
            actual_agent_root_path.join("conversations", conversation.id.to_s, ".lanes", conversation.chat_lane.id.to_s)
          end

          def comparable_path_for(path)
            candidate = Pathname.new(path.to_s)
            (candidate.exist? ? candidate.realpath : candidate.expand_path).to_s
          end

          def with_bundled_claw_bootstrap_env
            existing = BUNDLED_CLAW_BOOTSTRAP_ENVIRONMENT_VARIABLES.to_h { |key| [key, ENV[key]] }
            if existing.values.all? { |value| value.to_s.strip.present? }
              return yield
            end

            server =
              TestSupport::BundledClawRuntimeServer.new(
                source_root: ::Agents::BundledSources.path_for("claw"),
                workspace_root: workspace_root_base,
                deployment_fingerprint: BUNDLED_CLAW_BOOTSTRAP_FINGERPRINT,
                required_bearer: BUNDLED_CLAW_BOOTSTRAP_BEARER,
              ).start

            ENV["CYBROS_BOOTSTRAP_BUNDLED_CLAW_ENDPOINT_URL"] = server.rpc_url
            ENV["CYBROS_BOOTSTRAP_BUNDLED_CLAW_BEARER"] = BUNDLED_CLAW_BOOTSTRAP_BEARER
            ENV["CYBROS_BOOTSTRAP_BUNDLED_CLAW_FINGERPRINT"] = BUNDLED_CLAW_BOOTSTRAP_FINGERPRINT
            yield
          ensure
            existing&.each do |key, value|
              if value.nil?
                ENV.delete(key)
              else
                ENV[key] = value
              end
            end
            server&.shutdown
          end
      end
    end
  end
end

unless ENV["CYBROS_LIVE_ACCEPTANCE_NO_AUTORUN"] == "1"
  options = Cybros::LiveAcceptance::ClawWorkspaceEnvOverlay::Runner.parse_options(ARGV)
  Cybros::LiveAcceptance::ClawWorkspaceEnvOverlay::Runner.new(**options).run!
end
