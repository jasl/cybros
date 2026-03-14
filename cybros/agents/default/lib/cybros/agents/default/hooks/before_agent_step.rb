module Cybros
  module Agents
    module Default
      module Hooks
        class BeforeAgentStep
          def initialize(application:)
            @application = application
          end

          def call(params:)
            user_input = params.fetch("user_input", "").to_s.strip
            tokens = scenario_tokens(user_input)
            callback_session = params["callback_session"].is_a?(Hash) ? params["callback_session"] : {}
            system_entry = build_system_entry(params: params)

            result = {
              "planning" => {
                "step_plan" => {
                  "kind" => "bundled_default.before_agent_step.v2",
                  "summary" => build_summary(user_input),
                },
                "tool_surface" => build_tool_surface(params),
                "staged_mutations" => {
                  "prompt_buffer_ops" => [
                    {
                      "op" => "clear",
                      "buffer_name" => "system",
                    },
                    {
                      "op" => "put",
                      "entry" => system_entry,
                    },
                  ],
                },
              },
            }
            result.dig("planning", "step_plan")["fixture_scenarios"] = tokens if tokens.any?

            stage_state(result) if tokens.include?("stage-state")
            replay_kv(result) if tokens.include?("replay-kv")
            switch_target(callback_session:, params:, result:) if tokens.include?("switch-target")
            require_approval(result) if tokens.include?("approval")
            result
          end

          private

          def build_system_entry(params:)
            conversation_context = conversation_context_text(params)
            content = [@application.full_system_prompt, present_string(conversation_context)].compact.join("\n\n")

            {
              "id" => SecureRandom.uuid,
              "buffer_name" => "system",
              "seq" => 10,
              "kind" => "instruction",
              "content" => content,
              "priority" => 100,
              "estimated_tokens" => 0,
              "metadata" => { "source" => "before_agent_step" },
            }
          end

          def conversation_context_text(params)
            workspace = params.dig("session_context", "workspace")
            attachments = Array(params["attachment_manifest"]).select { |entry| entry.is_a?(Hash) }
            user_input = params.fetch("user_input", "").to_s.strip

            lines = []
            lines << "Latest request: #{user_input}" unless user_input.empty?

            if workspace.is_a?(Hash)
              root_path = workspace["logical_workspace_root_path"].to_s.strip
              workspace_key = workspace["logical_workspace_key"].to_s.strip
              lines << "Conversation workspace: #{root_path}" unless root_path.empty?
              lines << "Workspace key: #{workspace_key}" unless workspace_key.empty?
            end

            attachments.each_with_index do |attachment, index|
              filename = attachment["filename"].to_s.strip
              content_type = present_string(attachment["content_type"].to_s.strip) || "application/octet-stream"
              label = filename.empty? ? "(unnamed attachment)" : filename
              lines << "Attachment #{index + 1}: #{label} (#{content_type})"
            end
            return nil if lines.empty?

            "<conversation_runtime_context>\n#{lines.join("\n")}\n</conversation_runtime_context>"
          end

          def build_summary(user_input)
            return "inspect the current request and produce a concise assistant response" if user_input.empty?

            "inspect the current request and respond to: #{user_input}"
          end

          def scenario_tokens(user_input)
            user_input.to_s.scan(/\[fixture:([a-z0-9_-]+)\]/i).flatten.map(&:downcase)
          end

          def stage_state(result)
            result["planning"]["staged_mutations"].merge!(
              "public_settings_patch" => { "tone" => "concise" },
              "agent_config_patch" => { "mode" => "review" },
              "kv_ops" => [
                { "op" => "set", "key" => "shared.fixture.plan", "value" => { "status" => "planned" } },
              ],
            )
          end

          def replay_kv(result)
            result["planning"]["staged_mutations"]["kv_ops"] = [
              { "op" => "set", "key" => "shared.fixture.replay", "value" => { "status" => "deduped" } },
              { "op" => "set", "key" => "shared.fixture.replay", "value" => { "status" => "deduped" } },
            ]
          end

          def switch_target(callback_session:, params:, result:)
            targets = callback_rpc(callback_session, "execution_target.list", {}).fetch("targets", [])
            current_target_id = params["execution_target_id"].to_s
            alternate_target = paired_target_for(targets: targets, current_target_id: current_target_id)
            alternate_target ||= targets.find { |target| target["id"].to_s != current_target_id }
            return if alternate_target.nil?

            result["planning"]["execution_target_proposal"] = {
              "execution_target_id" => alternate_target.fetch("id"),
            }
          end

          def require_approval(result)
            result["planning"]["approval_request"] ||= { "status" => "pending_confirmation", "reason" => "fixture_approval" }
          end

          def build_tool_surface(params)
            snapshot = params["capability_snapshot"].is_a?(Hash) ? Manifest.deep_stringify(params["capability_snapshot"]) : {}
            snapshot_id = snapshot["capability_registry_snapshot_id"].to_s.strip
            selected_tool_ids =
              Array(snapshot["effective_tools"]).filter_map do |tool|
                next unless tool.is_a?(Hash)

                effective_tool_id = tool["effective_tool_id"].to_s.strip
                effective_tool_id unless effective_tool_id.empty?
              end.uniq
            return nil if snapshot_id.empty? || selected_tool_ids.empty?

            payload = {
              "capability_registry_snapshot_id" => snapshot_id,
              "selected_tool_ids" => selected_tool_ids,
              "tool_surface_label" => "bundled_default.before_agent_step",
            }
            callback_session = params["callback_session"].is_a?(Hash) ? params["callback_session"] : {}
            return payload if callback_session.empty?

            callback_rpc(callback_session, "tool_surface.manifest", payload)
          rescue StandardError
            manifest =
              Cybros::ProgrammableAgent::ToolSurfaceManifest.new(
                capability_registry_snapshot: Cybros::ProgrammableAgent::CapabilitySnapshot.restore(snapshot),
                selected_tool_ids: selected_tool_ids,
                tool_surface_label: payload["tool_surface_label"],
              )

            payload.merge(
              "tool_surface_id" => manifest.tool_surface_id,
              "logical_tool_names" => manifest.selected_tools.map(&:logical_tool_name),
            )
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
            return default_callback_result(method_name, params) if callback_session.empty?

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

          def default_callback_result(method_name, _params)
            case method_name
            when "execution_target.list"
              { "targets" => [] }
            when "tool_surface.manifest"
              {}
            else
              { "status" => "staged" }
            end
          end

          def present_string(value)
            string = value.to_s
            string.empty? ? nil : string
          end
        end
      end
    end
  end
end
