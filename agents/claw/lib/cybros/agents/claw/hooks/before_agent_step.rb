require "digest"

module Cybros
  module Agents
    module Claw
      module Hooks
        class BeforeAgentStep
          BOOTSTRAP_SOURCE_CHAR_CAP = 320
          BOOTSTRAP_TOTAL_CHAR_CAP = 900
          FULL_PROMPT_MODE = "full"
          MINIMAL_PROMPT_MODE = "minimal"

          def initialize(application:)
            @application = application
          end

          def call(params:)
            user_input = params.fetch("user_input", "").to_s.strip
            system_entry = build_system_entry(params: params)

            result = {
              "planning" => {
                "step_plan" => {
                  "kind" => "bundled_claw.before_agent_step.v2",
                  "summary" => build_summary(user_input)
                },
                "tool_surface" => build_tool_surface(params),
                "staged_mutations" => {
                  "prompt_buffer_ops" => [
                    {
                      "op" => "clear",
                      "buffer_name" => "system"
                    },
                    {
                      "op" => "put",
                      "entry" => system_entry
                    }
                  ]
                }
              }
            }
            result
          end

          private

          def build_system_entry(params:)
            content = build_system_prompt_content(params: params)

            {
              "id" => SecureRandom.uuid,
              "buffer_name" => "system",
              "seq" => 10,
              "kind" => "instruction",
              "content" => content,
              "priority" => 100,
              "estimated_tokens" => estimate_tokens(content),
              "metadata" => { "source" => "before_agent_step" }
            }
          end

          def build_system_prompt_content(params:)
            mode = prompt_mode(params)
            truncated_sources = []
            bootstrap_sources = build_bootstrap_sources(params: params, mode: mode, truncated_sources: truncated_sources)

            sections = []
            sections << build_section("Tooling", tooling_lines(params))
            sections << build_section("Safety", safety_lines(params))
            sections << build_section("Workspace", workspace_lines(params))
            sections << build_section("Scope Inventory", scope_inventory_lines(params)) if mode == FULL_PROMPT_MODE
            sections << build_section("Documentation", documentation_lines) if mode == FULL_PROMPT_MODE
            sections << build_section("Current Date & Time", current_date_time_lines)
            sections << build_section("Runtime", runtime_lines(params: params, mode: mode))
            if truncated_sources.any?
              sections << build_section(
                "Bootstrap Warning",
                [
                  "Some bootstrap sources were truncated to fit the prompt budget.",
                  "Truncated sources: #{truncated_sources.uniq.join(', ')}"
                ],
              )
            end
            sections << build_section("Bootstrap Context", bootstrap_sources) if bootstrap_sources.present?

            sections.compact.join("\n\n")
          end

          def prompt_mode(params)
            execution_scope = params.dig("execution_context", "execution_scope").to_s.strip
            return MINIMAL_PROMPT_MODE if execution_scope == "subagent"
            return MINIMAL_PROMPT_MODE if params.dig("execution_context", "subagent").is_a?(Hash)

            agent_profile = resolved_agent_profile(params)
            return MINIMAL_PROMPT_MODE if %w[subagent minimal].include?(agent_profile)

            FULL_PROMPT_MODE
          end

          def tooling_lines(params)
            tool_names = effective_tool_names(params)
            visible_tools = tool_names.first(12).join(", ")
            visible_tools += ", ..." if tool_names.length > 12
            [
              "Use only tools surfaced by the Cybros capability snapshot and tool.execute.",
              "Visible tools: #{visible_tools}"
            ]
          end

          def safety_lines(params)
            @application.prompt_text("system", params: params).to_s.strip.lines.map(&:chomp)
          end

          def workspace_lines(params)
            workspace = resolved_workspace(params)
            attachments = Array(params["attachment_manifest"]).select { |entry| entry.is_a?(Hash) }

            lines = []
            if workspace.any?
              root_path = workspace_root_path(workspace)
              conversation_path = workspace["conversation_path"].to_s.strip
              lane_path = workspace["lane_path"].to_s.strip
              cwd = workspace["cwd"].to_s.strip

              lines << "Agent root: #{root_path}" unless root_path.empty?
              lines << "Conversation path: #{conversation_path}" unless conversation_path.empty?
              lines << "Lane path: #{lane_path}" unless lane_path.empty?
              lines << "cwd: #{cwd}" unless cwd.empty?
            else
              lines << "Agent root: unavailable"
            end

            attachments.each_with_index do |attachment, index|
              filename = attachment["filename"].to_s.strip
              content_type = present_string(attachment["content_type"].to_s.strip) || "application/octet-stream"
              label = filename.empty? ? "(unnamed attachment)" : filename
              lines << "Attachment #{index + 1}: #{label} (#{content_type})"
            end

            lines
          end

          def scope_inventory_lines(params)
            workspace = resolved_workspace(params)
            return [] if workspace.empty?

            [
              *scope_state_lines(label: "root", path: workspace_root_path(workspace)),
              *scope_state_lines(label: "conversation", path: workspace["conversation_path"]),
              *scope_state_lines(label: "lane", path: workspace["lane_path"]),
            ]
          end

          def documentation_lines
            [
              "Consult local Cybros docs before inventing behavior or hidden control paths. Priority references: cybros/AGENTS.md, docs/dag/public_api.md, docs/plans/."
            ]
          end

          def current_date_time_lines
            now = Time.current
            [
              "Current time: #{now.iso8601} (#{Time.zone&.name || now.zone || 'UTC'})"
            ]
          end

          def runtime_lines(params:, mode:)
            execution_context = params["execution_context"].is_a?(Hash) ? params["execution_context"] : {}
            lines = []
            lines << "Execution scope: #{execution_context["execution_scope"].presence || (mode == MINIMAL_PROMPT_MODE ? "subagent" : "primary")}"
            lines << "Latest request: #{params.fetch("user_input", "").to_s.strip}" if params.fetch("user_input", "").present?
            if execution_context["subagent"].is_a?(Hash)
              subagent = execution_context["subagent"]
              lines << "Subagent id: #{subagent["subagent_id"]}" if subagent["subagent_id"].present?
            end
            lines
          end

          def build_bootstrap_sources(params:, mode:, truncated_sources:)
            sources = [
              [ "AGENTS", @application.prompt_text("agent", params: params) ],
              [ "TOOLS", synthesized_tools_source(params) ]
            ]
            if mode == FULL_PROMPT_MODE
              sources.insert(1, [ "SOUL", @application.prompt_text("soul", params: params) ])
              sources.insert(2, [ "USER", @application.prompt_text("user", params: params) ])
            end

            remaining_budget = BOOTSTRAP_TOTAL_CHAR_CAP
            rendered_sources = []

            sources.each do |name, content|
              normalized = normalize_bootstrap_source(name: name, content: content)
              next if normalized.empty?
              break if remaining_budget <= 0

              budgeted, truncated = truncate_bootstrap_source(name: name, content: normalized, remaining_budget: remaining_budget)
              truncated_sources << name if truncated
              rendered_sources << <<~SOURCE.chomp
                <bootstrap_source name="#{name}">
                #{budgeted}
                </bootstrap_source>
              SOURCE
              remaining_budget -= budgeted.length
            end

            rendered_sources.join("\n\n")
          end

          def truncate_bootstrap_source(name:, content:, remaining_budget:)
            marker = "\n...[truncated #{name}]"
            effective_cap = [ BOOTSTRAP_SOURCE_CHAR_CAP, remaining_budget ].min
            return [ content, false ] if content.length <= effective_cap

            available = effective_cap - marker.length
            return [ marker.strip, true ] if available <= 0

            [ content.slice(0, available) + marker, true ]
          end

          def normalize_bootstrap_source(name:, content:)
            normalized = content.to_s.strip
            return normalized if normalized.empty?

            case name
            when "AGENTS", "SOUL", "USER"
              excerpt_bootstrap_text(normalized, max_chars: 120)
            else
              normalized
            end
          end

          def excerpt_bootstrap_text(content, max_chars:)
            lines = content.lines.map(&:strip).reject(&:empty?)
            summary = lines.first(2).join(" ")
            return summary if summary.length <= max_chars

            summary.slice(0, max_chars)
          end

          def synthesized_tools_source(params)
            tool_names = effective_tool_names(params)
            return "No agent-owned tools were surfaced for this step." if tool_names == [ "(none supplied)" ]

            "Logical tools: #{tool_names.join(', ')}"
          end

          def resolved_agent_profile(params)
            conversation = resolved_conversation(params)
            return nil if conversation.nil?

            metadata = conversation.respond_to?(:metadata) && conversation.metadata.is_a?(Hash) ? conversation.metadata.deep_stringify_keys : {}
            metadata.dig("agent", "agent_profile").to_s.strip.presence
          rescue StandardError
            nil
          end

          def resolved_conversation(params)
            conversation_class = "Conversation".safe_constantize
            return nil if conversation_class.nil?

            conversation_id =
              params.dig("execution_context", "conversation_id").to_s.strip.presence ||
                params.dig("session_context", "conversation_id").to_s.strip.presence ||
                params["conversation_id"].to_s.strip.presence
            return nil if conversation_id.blank?

            conversation_class.find_by(id: conversation_id)
          rescue StandardError
            nil
          end

          def effective_tool_names(params)
            tool_names =
              Array(params.dig("capability_snapshot", "effective_tools")).filter_map do |entry|
                next unless entry.is_a?(Hash)

                entry["logical_tool_name"].to_s.strip.presence
              end
            return [ "(none supplied)" ] if tool_names.empty?

            tool_names.uniq
          end

          def resolved_workspace(params)
            workspace = params.dig("execution_context", "workspace")
            workspace = params.dig("session_context", "workspace") unless workspace.is_a?(Hash) && workspace.any?
            workspace.is_a?(Hash) ? workspace : {}
          rescue StandardError
            {}
          end

          def workspace_root_path(workspace)
            workspace["root_path"].to_s.strip
          end

          def scope_state_lines(label:, path:)
            scope_path = path.to_s.strip
            return ["#{label} MEMORY.md: unavailable", "#{label} today log: unavailable"] if scope_path.empty?

            root = Pathname.new(scope_path)
            [
              "#{label} MEMORY.md: #{root.join("MEMORY.md").file? ? "present" : "absent"}",
              "#{label} today log: #{root.join(DailyMemoryTarget.call).file? ? "present" : "absent"}",
            ]
          rescue StandardError
            ["#{label} MEMORY.md: unavailable", "#{label} today log: unavailable"]
          end

          def build_section(title, lines)
            normalized_lines =
              Array(lines).filter_map do |line|
                text = line.to_s.rstrip
                text.empty? ? nil : text
              end
            return nil if normalized_lines.empty?

            ([ "## #{title}" ] + normalized_lines).join("\n")
          end

          def estimate_tokens(text)
            [ (text.to_s.length / 4.0).ceil, 1 ].max
          end

          def build_summary(user_input)
            return "inspect the current request and produce a concise assistant response" if user_input.empty?

            "inspect the current request and respond to: #{user_input}"
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
              "tool_surface_label" => "bundled_claw.before_agent_step"
            }
            callback_session = params["callback_session"].is_a?(Hash) ? params["callback_session"] : {}
            return payload if callback_session.empty?

            callback_rpc(callback_session, "tool_surface.manifest", payload)
          rescue StandardError
            local_tool_surface_manifest(snapshot: snapshot, payload: payload)
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

          def local_tool_surface_manifest(snapshot:, payload:)
            selected_tool_ids = Array(payload["selected_tool_ids"]).map(&:to_s).reject(&:empty?).uniq
            effective_tools =
              Array(snapshot["effective_tools"]).filter_map do |tool|
                next unless tool.is_a?(Hash)

                normalized_tool = Manifest.deep_stringify(tool)
                effective_tool_id = normalized_tool["effective_tool_id"].to_s.strip
                next if effective_tool_id.empty?

                [effective_tool_id, normalized_tool]
              end.to_h

            {
              "capability_registry_snapshot_id" => snapshot["capability_registry_snapshot_id"].to_s,
              "tool_surface_id" => local_tool_surface_id(snapshot:, selected_tool_ids: selected_tool_ids),
              "tool_surface_label" => present_string(payload["tool_surface_label"]),
              "selected_tool_ids" => selected_tool_ids,
              "logical_tool_names" =>
                selected_tool_ids.filter_map do |tool_id|
                  logical_tool_name = effective_tools.dig(tool_id, "logical_tool_name").to_s.strip
                  logical_tool_name unless logical_tool_name.empty?
                end,
            }.compact
          end

          def local_tool_surface_id(snapshot:, selected_tool_ids:)
            payload = {
              capability_registry_snapshot_id: snapshot["capability_registry_snapshot_id"].to_s,
              selected_tool_ids: Array(selected_tool_ids).map(&:to_s).reject(&:empty?).uniq.sort,
            }

            "surface_#{Digest::SHA256.hexdigest(JSON.generate(payload)).first(24)}"
          end
        end
      end
    end
  end
end
