module Cybros
  module Agents
    module Default
      module Hooks
        class Prepare
          def initialize(application:)
            @application = application
          end

          def call(params:)
            user_input = params.fetch("user_input", "").to_s.strip
            tokens = scenario_tokens(user_input)
            callback_session = params["callback_session"].is_a?(Hash) ? params["callback_session"] : {}

            result = {
              "prepared_plan" => {
                "kind" => "bundled_default.prepare.v1",
                "summary" => build_summary(user_input),
              },
              "prompt_fragments" => [
                { "role" => "system", "content" => @application.full_system_prompt },
              ],
            }
            result["prepared_plan"]["fixture_scenarios"] = tokens if tokens.any?

            stage_state(callback_session) if tokens.include?("stage-state")
            replay_kv(callback_session) if tokens.include?("replay-kv")
            switch_target(callback_session:, params:, result:) if tokens.include?("switch-target")
            require_approval(result) if tokens.include?("approval")
            result
          end

          private

          def build_summary(user_input)
            return "inspect the current request and produce a concise assistant response" if user_input.empty?

            "inspect the current request and respond to: #{user_input}"
          end

          def scenario_tokens(user_input)
            user_input.to_s.scan(/\[fixture:([a-z0-9_-]+)\]/i).flatten.map(&:downcase)
          end

          def stage_state(callback_session)
            callback_rpc(callback_session, "conversation.settings.update",
                         { "operation_id" => "fixture-settings", "patch" => { "tone" => "concise" } })
            callback_rpc(callback_session, "conversation.config.update",
                         { "operation_id" => "fixture-config", "patch" => { "mode" => "review" } })
            callback_rpc(
              callback_session,
              "conversation.kv.set",
              { "operation_id" => "fixture-kv", "key" => "shared.fixture.plan", "value" => { "status" => "planned" } }
            )
          end

          def replay_kv(callback_session)
            2.times do
              callback_rpc(
                callback_session,
                "conversation.kv.set",
                { "operation_id" => "fixture-kv-replay", "key" => "shared.fixture.replay",
                  "value" => { "status" => "deduped" } }
              )
            end
          end

          def switch_target(callback_session:, params:, result:)
            targets = callback_rpc(callback_session, "execution_target.list", {}).fetch("targets", [])
            current_target_id = params["execution_target_id"].to_s
            alternate_target = paired_target_for(targets: targets, current_target_id: current_target_id)
            alternate_target ||= targets.find { |target| target["id"].to_s != current_target_id }
            return if alternate_target.nil?

            proposal =
              callback_rpc(
                callback_session,
                "execution_target.propose",
                { "operation_id" => "fixture-target-switch", "execution_target_id" => alternate_target.fetch("id") }
              )
            return unless proposal.dig("switch_decision", "decision").to_s == "confirm"

            result["approval_state"] = {
              "status" => "pending_confirmation",
              "reason" => "target_switch",
              "proposed_execution_target_id" => alternate_target.fetch("id"),
            }
          end

          def require_approval(result)
            result["approval_state"] ||= { "status" => "pending_confirmation", "reason" => "fixture_approval" }
          end

          def paired_target_for(targets:, current_target_id:)
            current_target = targets.find { |target| target["id"].to_s == current_target_id.to_s }
            return nil if current_target.nil?

            current_name = current_target["name"].to_s
            paired_name =
              if current_name.end_with?(" Primary")
                "#{current_name.delete_suffix(" Primary")} Alternate"
              elsif current_name.end_with?(" Alternate")
                "#{current_name.delete_suffix(" Alternate")} Primary"
              end
            return nil if paired_name.to_s.empty?

            targets.find { |target| target["id"].to_s != current_target_id.to_s && target["name"].to_s == paired_name }
          end

          def callback_rpc(callback_session, method_name, params)
            return default_callback_result(method_name) if callback_session.empty?

            uri = URI(callback_session.fetch("endpoint"))
            request = Net::HTTP::Post.new(uri)
            request["Content-Type"] = "application/json"
            request["Authorization"] = "Bearer #{callback_session.fetch("bearer")}"
            request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => SecureRandom.uuid, "method" => method_name,
                                           "params" => params })

            response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
            raise "callback #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

            payload = JSON.parse(response.body)
            raise "callback error: #{payload.fetch("error").inspect}" if payload["error"]

            payload.fetch("result")
          end

          def default_callback_result(method_name)
            method_name == "execution_target.list" ? { "targets" => [] } : { "status" => "staged" }
          end
        end
      end
    end
  end
end
