# frozen_string_literal: true

require "json"

module AgentCore
  module Resources
    module Tools
      class ToolNameRepairLoop
        DEFAULT_TEMPERATURE = 0
        DEFAULT_ARGUMENTS_PREVIEW_BYTES = 1_000
        DEFAULT_MAX_VISIBLE_TOOL_NAMES = 200
        DEFAULT_MAX_CANDIDATES = 10

        def self.call(
          provider:,
          requested_model:,
          fallback_models:,
          tool_calls:,
          visible_tools:,
          tools_registry:,
          max_attempts:,
          max_output_tokens:,
          max_candidates: DEFAULT_MAX_CANDIDATES,
          max_visible_tool_names: DEFAULT_MAX_VISIBLE_TOOL_NAMES,
          tool_name_aliases: {},
          tool_name_normalize_fallback: false,
          options:,
          instrumenter:,
          run_id:
        )
          new(
            provider: provider,
            requested_model: requested_model,
            fallback_models: fallback_models,
            tool_calls: tool_calls,
            visible_tools: visible_tools,
            tools_registry: tools_registry,
            max_attempts: max_attempts,
            max_output_tokens: max_output_tokens,
            max_candidates: max_candidates,
            max_visible_tool_names: max_visible_tool_names,
            tool_name_aliases: tool_name_aliases,
            tool_name_normalize_fallback: tool_name_normalize_fallback,
            options: options,
            instrumenter: instrumenter,
            run_id: run_id,
          ).call
        end

        def initialize(provider:, requested_model:, fallback_models:, tool_calls:, visible_tools:, tools_registry:, max_attempts:, max_output_tokens:, max_candidates:, max_visible_tool_names:, tool_name_aliases:, tool_name_normalize_fallback:, options:, instrumenter:, run_id:)
          @provider = provider
          @requested_model = requested_model.to_s
          @fallback_models = Array(fallback_models)
          @tool_calls = Array(tool_calls)
          @visible_tools = Array(visible_tools)
          @tools_registry = tools_registry
          @max_attempts = Integer(max_attempts)
          @max_attempts = 0 if @max_attempts.negative?
          @max_output_tokens = Integer(max_output_tokens)
          @max_output_tokens = 1 if @max_output_tokens <= 0
          @max_candidates = Integer(max_candidates)
          @max_candidates = DEFAULT_MAX_CANDIDATES if @max_candidates <= 0
          @max_visible_tool_names = Integer(max_visible_tool_names)
          @max_visible_tool_names = DEFAULT_MAX_VISIBLE_TOOL_NAMES if @max_visible_tool_names <= 0
          @tool_name_aliases = tool_name_aliases
          @tool_name_normalize_fallback = tool_name_normalize_fallback == true
          @options = options.is_a?(Hash) ? options : {}
          @instrumenter = instrumenter
          @run_id = run_id.to_s
        end

        def call
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          visible_tool_names_all = extract_visible_tool_names(@visible_tools)
          visible_tools_total = visible_tool_names_all.length

          visible_tool_names =
            visible_tool_names_all
              .sort
              .first(@max_visible_tool_names)

          visible_tools_sent = visible_tool_names.length
          visible_tools_truncated = visible_tools_total > visible_tools_sent

          visible_name_set = {}
          visible_tool_names.each { |n| visible_name_set[n] = true }

          normalize_index_visible =
            if @tool_name_normalize_fallback
              AgentCore::Resources::Tools::ToolNameResolver.build_normalize_index(visible_tool_names)
            end

          normalize_index_registry =
            if @tool_name_normalize_fallback && @tools_registry.respond_to?(:tool_names)
              AgentCore::Resources::Tools::ToolNameResolver.build_normalize_index(@tools_registry.tool_names)
            end

          candidates_all = []
          skipped = 0
          failures_sample = []

          @tool_calls.each do |tc|
            tool_call_id = safe_tool_call_id(tc)
            if tool_call_id == "unknown"
              skipped += 1
              failures_sample << { "tool_call_id" => tool_call_id, "reason" => "missing_tool_call_id" }
              next
            end

            requested_name = tc.respond_to?(:name) ? tc.name.to_s : ""
            requested_name = requested_name.strip
            if requested_name.empty?
              skipped += 1
              failures_sample << { "tool_call_id" => tool_call_id, "reason" => "missing_tool_name" }
              next
            end

            visible_resolution =
              AgentCore::Resources::Tools::ToolNameResolver.resolve(
                requested_name,
                include_check: ->(name) { visible_name_set.key?(name) },
                aliases: @tool_name_aliases,
                enable_normalize_fallback: @tool_name_normalize_fallback,
                normalize_index: normalize_index_visible,
              )

            next if visible_name_set.key?(visible_resolution.resolved_name)

            reason =
              begin
                registry_resolution =
                  AgentCore::Resources::Tools::ToolNameResolver.resolve(
                    requested_name,
                    include_check: ->(name) { @tools_registry&.include?(name) },
                    aliases: @tool_name_aliases,
                    enable_normalize_fallback: @tool_name_normalize_fallback,
                    normalize_index: normalize_index_registry,
                  )

                if @tools_registry&.include?(registry_resolution.resolved_name)
                  "tool_not_in_profile"
                else
                  "tool_not_found"
                end
              rescue StandardError
                "tool_not_found"
              end

            candidates_all << {
              tool_call_id: tool_call_id,
              requested_name: requested_name,
              reason: reason,
              arguments_preview: arguments_preview(tc),
            }
          end

          candidates_total = candidates_all.length
          candidates_sent =
            if candidates_total > @max_candidates
              overflow = candidates_all.drop(@max_candidates)
              overflow.each do |c|
                failures_sample << { "tool_call_id" => c.fetch(:tool_call_id).to_s, "reason" => "skipped_by_max_candidates" }
              rescue StandardError
                next
              end
              candidates_all.first(@max_candidates)
            else
              candidates_all
            end

          if candidates_sent.empty? || @max_attempts <= 0 || visible_tool_names.empty?
            metadata =
              build_metadata(
                attempts: 0,
                candidates_total: candidates_total,
                candidates_sent: candidates_sent.length,
                repaired: 0,
                failed: candidates_total,
                skipped: skipped,
                model: nil,
                visible_tools_total: visible_tools_total,
                visible_tools_sent: visible_tools_sent,
                visible_tools_truncated: visible_tools_truncated,
                repairs_sample: [],
                failures_sample: failures_sample,
              )

            return { tool_name_repairs: {}, metadata: metadata }
          end

          models = normalize_models(@requested_model, @fallback_models)

          attempts = 0
          used_model = nil
          payload = nil

          prompt_messages = [
            AgentCore::Message.new(role: :system, content: repair_system_prompt),
            AgentCore::Message.new(role: :user, content: repair_user_prompt(visible_tool_names, candidates_sent)),
          ]

          @max_attempts.times do |attempt_idx|
            used_model = models.fetch(attempt_idx, models.last)
            attempts += 1

            attempt_messages =
              if attempt_idx.zero?
                prompt_messages
              else
                prompt_messages + [AgentCore::Message.new(role: :user, content: retry_instructions(attempt_idx))]
              end

            response_text =
              begin
                resp =
                  @provider.chat(
                    messages: attempt_messages,
                    model: used_model,
                    tools: nil,
                    stream: false,
                    **repair_options
                  )

                resp.respond_to?(:message) ? resp.message&.text.to_s : resp.to_s
              rescue StandardError => e
                failures_sample << { "tool_call_id" => "", "reason" => "provider_error=#{e.class}" }
                next
              end

            parsed = parse_repair_payload(response_text)
            unless parsed
              failures_sample << { "tool_call_id" => "", "reason" => "json_parse_failed" }
              next
            end

            payload = parsed
            break
          end

          tool_name_repairs, repaired_count, apply_failures, repairs_sample =
            apply_repairs(
              payload,
              candidates: candidates_sent,
              visible_name_set: visible_name_set,
            )

          failures_sample.concat(apply_failures)

          elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0

          publish_event(
            candidates: candidates_total,
            repaired: repaired_count,
            failed: candidates_total - repaired_count,
            model: used_model,
            elapsed_ms: elapsed_ms,
          )

          metadata =
            build_metadata(
              attempts: attempts,
              candidates_total: candidates_total,
              candidates_sent: candidates_sent.length,
              repaired: repaired_count,
              failed: candidates_total - repaired_count,
              skipped: skipped,
              model: used_model,
              visible_tools_total: visible_tools_total,
              visible_tools_sent: visible_tools_sent,
              visible_tools_truncated: visible_tools_truncated,
              repairs_sample: repairs_sample,
              failures_sample: failures_sample,
            )

          { tool_name_repairs: tool_name_repairs, metadata: metadata }
        rescue StandardError => e
          failures_sample = [{ "tool_call_id" => "", "reason" => "tool_name_repair_loop_error=#{e.class}" }]
          metadata =
            build_metadata(
              attempts: 0,
              candidates_total: 0,
              candidates_sent: 0,
              repaired: 0,
              failed: 0,
              skipped: 0,
              model: nil,
              visible_tools_total: 0,
              visible_tools_sent: 0,
              visible_tools_truncated: false,
              repairs_sample: [],
              failures_sample: failures_sample,
            )

          { tool_name_repairs: {}, metadata: metadata }
        end

        private

        def repair_system_prompt
          <<~TEXT
            You fix tool call names so they match the tools visible to the model.

            Output MUST be a single JSON object (no markdown, no code fences), with this exact shape:
            {"repairs":[{"tool_call_id":"...","name":"..."}]}

            Rules:
            - Only include entries for tool_call_ids you can repair.
            - "name" MUST be one of the provided visible_tool_names exactly.
            - Do NOT include any other keys.
          TEXT
        end

        def repair_user_prompt(visible_tool_names, candidates)
          payload = {
            "visible_tool_names" => visible_tool_names,
            "candidates" => candidates.map { |c| candidate_for_prompt(c) },
          }
          JSON.generate(payload)
        rescue StandardError
          ""
        end

        def candidate_for_prompt(candidate)
          {
            "tool_call_id" => candidate.fetch(:tool_call_id).to_s,
            "requested_name" => candidate.fetch(:requested_name).to_s,
            "reason" => candidate.fetch(:reason).to_s,
            "arguments_preview" => candidate.fetch(:arguments_preview).to_s,
          }
        rescue StandardError
          {}
        end

        def retry_instructions(attempt_idx)
          <<~TEXT
            Previous output was invalid JSON or did not match the required shape.
            Retry attempt #{attempt_idx + 1}: Output ONLY the JSON object with exactly {"repairs":[{"tool_call_id":"...","name":"..."}]}.
          TEXT
        end

        def repair_options
          out = AgentCore::Utils.deep_symbolize_keys(@options)
          out.delete(:stream)
          out[:max_tokens] = @max_output_tokens
          out[:temperature] = DEFAULT_TEMPERATURE unless out.key?(:temperature)
          out
        rescue StandardError
          { max_tokens: @max_output_tokens, temperature: DEFAULT_TEMPERATURE }
        end

        def apply_repairs(payload, candidates:, visible_name_set:)
          failures = []
          repairs_sample = []

          candidate_by_id = {}
          Array(candidates).each do |c|
            id = c.fetch(:tool_call_id, "").to_s
            next if id.strip.empty?

            candidate_by_id[id] = c
          rescue StandardError
            next
          end

          return [{}, 0, [{ "tool_call_id" => "", "reason" => "invalid_shape" }], []] unless payload.is_a?(Hash)

          repairs = payload.fetch("repairs", nil)
          return [{}, 0, [{ "tool_call_id" => "", "reason" => "invalid_shape" }], []] unless repairs.is_a?(Array)

          tool_name_repairs = {}
          repaired = 0

          repairs.each do |entry|
            next unless entry.is_a?(Hash)

            tool_call_id = entry.fetch("tool_call_id", "").to_s
            next if tool_call_id.strip.empty?
            next unless (candidate = candidate_by_id[tool_call_id])

            name = entry.fetch("name", "").to_s
            name = name.strip
            if name.empty?
              failures << { "tool_call_id" => tool_call_id, "reason" => "missing_name" }
              next
            end

            unless visible_name_set.key?(name)
              failures << { "tool_call_id" => tool_call_id, "reason" => "name_not_in_visible_tools" }
              next
            end

            tool_name_repairs[tool_call_id] = name
            repaired += 1

            if repairs_sample.length < 20
              repairs_sample << {
                "tool_call_id" => tool_call_id,
                "requested_name" => candidate.fetch(:requested_name).to_s,
                "repaired_name" => name,
                "reason" => candidate.fetch(:reason).to_s,
              }
            end
          end

          [tool_name_repairs, repaired, failures.first(10), repairs_sample]
        rescue StandardError
          [{}, 0, [{ "tool_call_id" => "", "reason" => "apply_repairs_error" }], []]
        end

        def parse_repair_payload(text)
          str = text.to_s.strip
          return nil if str.empty?

          fenced = str.match(/\A```(?:json)?\s*(.*?)\s*```\z/mi)
          str = fenced[1].to_s.strip if fenced

          JSON.parse(str)
        rescue JSON::ParserError
          begin
            start_idx = str.index("{")
            end_idx = str.rindex("}")
            return nil unless start_idx && end_idx && end_idx > start_idx

            JSON.parse(str[start_idx..end_idx])
          rescue StandardError
            nil
          end
        rescue StandardError
          nil
        end

        def extract_visible_tool_names(tools)
          out = []

          Array(tools).each do |tool|
            next unless tool.is_a?(Hash)

            h = AgentCore::Utils.symbolize_keys(tool)

            name = h.fetch(:name, nil).to_s
            if name.strip.empty?
              type = h.fetch(:type, nil).to_s
              if type == "function" && h.fetch(:function, nil).is_a?(Hash)
                fn = AgentCore::Utils.symbolize_keys(h.fetch(:function))
                name = fn.fetch(:name, nil).to_s
              end
            end

            name = name.strip
            next if name.empty?

            out << name
          rescue StandardError
            next
          end

          out.uniq
        rescue StandardError
          []
        end

        def arguments_preview(tc)
          raw = tc.respond_to?(:arguments_raw) ? tc.arguments_raw : nil
          if raw
            return AgentCore::Utils.truncate_utf8_bytes(raw, max_bytes: DEFAULT_ARGUMENTS_PREVIEW_BYTES)
          end

          args = tc.respond_to?(:arguments) ? tc.arguments : {}
          args = {} unless args.is_a?(Hash)

          json = JSON.generate(args)
          AgentCore::Utils.truncate_utf8_bytes(json, max_bytes: DEFAULT_ARGUMENTS_PREVIEW_BYTES)
        rescue StandardError
          ""
        end

        def safe_tool_call_id(tc)
          id = tc.respond_to?(:id) ? tc.id.to_s : ""
          id = id.strip
          id.empty? ? "unknown" : id
        rescue StandardError
          "unknown"
        end

        def normalize_models(requested_model, fallback_models)
          list = [requested_model.to_s, *Array(fallback_models).map(&:to_s)]
          list = list.map { |m| m.to_s.strip }.reject(&:empty?)

          seen = {}
          list.each_with_object([]) do |m, out|
            next if seen[m]

            seen[m] = true
            out << m
          end
        end

        def publish_event(candidates:, repaired:, failed:, model:, elapsed_ms:)
          model_name = model.to_s.strip
          model_name = nil if model_name.empty?

          payload = {
            run_id: @run_id,
            candidates: candidates,
            repaired: repaired,
            failed: failed,
            model: model_name,
            elapsed_ms: elapsed_ms,
          }.compact

          @instrumenter.publish("agent_core.tool.name_repair", payload) if @instrumenter.respond_to?(:publish)
        rescue StandardError
          nil
        end

        def build_metadata(attempts:, candidates_total:, candidates_sent:, repaired:, failed:, skipped:, model:, visible_tools_total:, visible_tools_sent:, visible_tools_truncated:, repairs_sample:, failures_sample:)
          model_name = model.to_s.strip
          model_name = nil if model_name.empty?

          sample = Array(failures_sample).first(10)
          sample = sample.map { |h| h.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(h) : { "reason" => h.to_s } }

          {
            "tool_loop" => {
              "tool_name_repair" => {
                "attempts" => attempts,
                "candidates_total" => candidates_total,
                "candidates_sent" => candidates_sent,
                "repaired" => repaired,
                "failed" => failed,
                "skipped" => skipped,
                "model" => model_name,
                "visible_tools_total" => visible_tools_total,
                "visible_tools_sent" => visible_tools_sent,
                "visible_tools_truncated" => visible_tools_truncated == true,
                "repairs_sample" => Array(repairs_sample).first(20),
                "failures_sample" => sample,
              }.compact,
            },
          }
        rescue StandardError
          {}
        end
      end
    end
  end
end
