# frozen_string_literal: true

require "json"

module AgentCore
  module Resources
    module Tools
      class ToolCallRepairLoop
        DEFAULT_TEMPERATURE = 0
        DEFAULT_ARGUMENTS_RAW_PREVIEW_BYTES = 1_000
        DEFAULT_MAX_SCHEMA_BYTES = 8_000
        DEFAULT_MAX_CANDIDATES = 10

        def self.call(
          provider:,
          requested_model:,
          fallback_models:,
          tool_calls:,
          visible_tools:,
          max_output_tokens:,
          max_attempts:,
          validate_schema: false,
          schema_max_depth: 2,
          max_schema_bytes: DEFAULT_MAX_SCHEMA_BYTES,
          max_candidates: DEFAULT_MAX_CANDIDATES,
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
            max_output_tokens: max_output_tokens,
            max_attempts: max_attempts,
            validate_schema: validate_schema,
            schema_max_depth: schema_max_depth,
            max_schema_bytes: max_schema_bytes,
            max_candidates: max_candidates,
            tool_name_aliases: tool_name_aliases,
            tool_name_normalize_fallback: tool_name_normalize_fallback,
            options: options,
            instrumenter: instrumenter,
            run_id: run_id,
          ).call
        end

        def initialize(provider:, requested_model:, fallback_models:, tool_calls:, visible_tools:, max_output_tokens:, max_attempts:, validate_schema:, schema_max_depth:, max_schema_bytes:, max_candidates:, tool_name_aliases:, tool_name_normalize_fallback:, options:, instrumenter:, run_id:)
          @provider = provider
          @requested_model = requested_model.to_s
          @fallback_models = Array(fallback_models)
          @tool_calls = Array(tool_calls)
          @visible_tools = Array(visible_tools)
          @max_output_tokens = Integer(max_output_tokens)
          @max_attempts = Integer(max_attempts)
          @validate_schema = validate_schema == true
          @schema_max_depth = Integer(schema_max_depth)
          @schema_max_depth = 0 if @schema_max_depth.negative?
          @max_schema_bytes = Integer(max_schema_bytes)
          @max_schema_bytes = DEFAULT_MAX_SCHEMA_BYTES if @max_schema_bytes <= 0
          @max_candidates = Integer(max_candidates)
          @max_candidates = DEFAULT_MAX_CANDIDATES if @max_candidates <= 0
          @tool_name_aliases = tool_name_aliases
          @tool_name_normalize_fallback = tool_name_normalize_fallback == true
          @options = options.is_a?(Hash) ? options : {}
          @instrumenter = instrumenter
          @run_id = run_id.to_s
        end

        def call
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          tool_map = index_visible_tools(@visible_tools)
          normalize_index =
            if @tool_name_normalize_fallback
              AgentCore::Resources::Tools::ToolNameResolver.build_normalize_index(tool_map.keys)
            end

          candidates_all = []
          skipped = 0
          failures_sample = []

          @tool_calls.each do |tc|
            parse_error = tc.respond_to?(:arguments_parse_error) ? tc.arguments_parse_error : nil
            parse_reason = targeted_parse_error_reason(parse_error)

            tool_call_id = safe_tool_call_id(tc)
            if tool_call_id == "unknown"
              skipped += 1
              failures_sample << { "tool_call_id" => tool_call_id, "reason" => "missing_tool_call_id" }
              next
            end

            tool_name = tc.respond_to?(:name) ? tc.name.to_s : ""
            tool_name = tool_name.strip
            if tool_name.empty?
              skipped += 1
              failures_sample << { "tool_call_id" => tool_call_id, "reason" => "missing_tool_name" }
              next
            end

            resolution =
              AgentCore::Resources::Tools::ToolNameResolver.resolve(
                tool_name,
                include_check: ->(name) { tool_map.key?(name) },
                aliases: @tool_name_aliases,
                enable_normalize_fallback: @tool_name_normalize_fallback,
                normalize_index: normalize_index,
              )

            tool = tool_map[resolution.resolved_name]
            unless tool
              skipped += 1
              failures_sample << { "tool_call_id" => tool_call_id, "reason" => "tool_not_visible" }
              next
            end

            schema = tool.fetch(:schema, {})

            if parse_reason
              strict_schema = StrictJsonSchema.normalize(schema)
              schema_for_prompt, schema_truncated = prepare_schema_for_prompt(strict_schema)

              raw = tc.respond_to?(:arguments_raw) ? tc.arguments_raw : nil
              raw_preview =
                if raw
                  AgentCore::Utils.truncate_utf8_bytes(raw, max_bytes: DEFAULT_ARGUMENTS_RAW_PREVIEW_BYTES)
                else
                  ""
                end

              if raw_preview.strip.empty?
                skipped += 1
                failures_sample << { "tool_call_id" => tool_call_id, "reason" => "missing_arguments_raw" }
                next
              end

              candidates_all << {
                tool_call_id: tool_call_id,
                tool_name: tool.fetch(:name),
                parse_error: parse_error.to_s,
                arguments_raw_preview: raw_preview,
                schema: schema_for_prompt,
                schema_truncated: schema_truncated,
                validation_errors_summary: "",
              }
              next
            end

            next unless @validate_schema

            strict_schema = StrictJsonSchema.normalize(schema)

            args = tc.respond_to?(:arguments) ? tc.arguments : {}
            args = {} unless args.is_a?(Hash)

            errors = AgentCore::Resources::Tools::JsonSchemaLiteValidator.validate(arguments: args, schema: strict_schema, max_depth: @schema_max_depth)
            next if errors.empty?

            schema_for_prompt, schema_truncated = prepare_schema_for_prompt(strict_schema)

            args_preview =
              begin
                json = JSON.generate(args)
                AgentCore::Utils.truncate_utf8_bytes(json, max_bytes: DEFAULT_ARGUMENTS_RAW_PREVIEW_BYTES)
              rescue StandardError
                ""
              end

            if args_preview.strip.empty?
              skipped += 1
              failures_sample << { "tool_call_id" => tool_call_id, "reason" => "missing_arguments_preview" }
              next
            end

            candidates_all << {
              tool_call_id: tool_call_id,
              tool_name: tool.fetch(:name),
              parse_error: "schema_invalid",
              arguments_raw_preview: args_preview,
              schema: schema_for_prompt,
              schema_truncated: schema_truncated,
              validation_errors_summary: AgentCore::Resources::Tools::JsonSchemaLiteValidator.summarize(errors),
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
          schema_truncated_candidates = candidates_sent.count { |c| c[:schema_truncated] == true }

          if candidates_sent.empty? || @max_attempts <= 0
            metadata =
              build_metadata(
                attempts: 0,
                candidates: candidates_total,
                candidates_total: candidates_total,
                candidates_sent: candidates_sent.length,
                repaired: 0,
                failed: candidates_total,
                skipped: skipped,
                max_schema_bytes: @max_schema_bytes,
                schema_truncated_candidates: schema_truncated_candidates,
                failures_sample: failures_sample,
                model: nil,
              )

            return { tool_calls: @tool_calls, metadata: metadata }
          end

          models = normalize_models(@requested_model, @fallback_models)

          attempts = 0
          used_model = nil
          repairs_payload = nil

          system = repair_system_prompt
          user = repair_user_prompt(candidates_sent)
          prompt_messages = [
            AgentCore::Message.new(role: :system, content: system),
            AgentCore::Message.new(role: :user, content: user),
          ]

          @max_attempts.times do |attempt_idx|
            model = models.fetch(attempt_idx, models.last)
            used_model = model
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
                    model: model,
                    tools: nil,
                    stream: false,
                    **repair_options
                  )
                resp.respond_to?(:message) ? resp.message&.text.to_s : resp.to_s
              rescue StandardError => e
                failures_sample << { "tool_call_id" => "", "reason" => "provider_error=#{e.class}" }
                next
              end

            payload = parse_repair_payload(response_text)
            unless payload
              failures_sample << { "tool_call_id" => "", "reason" => "json_parse_failed" }
              next
            end

            repairs_payload = payload
            break
          end

          repaired_tool_calls, repaired_count, _failed_count, apply_failures =
            apply_repairs(@tool_calls, repairs_payload, candidates: candidates_sent)

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
              candidates: candidates_total,
              candidates_total: candidates_total,
              candidates_sent: candidates_sent.length,
              repaired: repaired_count,
              failed: candidates_total - repaired_count,
              skipped: skipped,
              max_schema_bytes: @max_schema_bytes,
              schema_truncated_candidates: schema_truncated_candidates,
              failures_sample: failures_sample,
              model: used_model,
            )

          { tool_calls: repaired_tool_calls, metadata: metadata }
        rescue StandardError => e
          failures_sample = [{ "tool_call_id" => "", "reason" => "repair_loop_error=#{e.class}" }]
          metadata =
            build_metadata(
              attempts: 0,
              candidates: 0,
              candidates_total: 0,
              candidates_sent: 0,
              repaired: 0,
              failed: 0,
              skipped: 0,
              max_schema_bytes: @max_schema_bytes,
              schema_truncated_candidates: 0,
              failures_sample: failures_sample,
              model: nil,
            )
          { tool_calls: @tool_calls, metadata: metadata }
        end

        private

        def repair_system_prompt
          <<~TEXT
            You fix tool call arguments that are invalid (either they failed to parse as JSON, or they failed schema validation).

            Output MUST be a single JSON object (no markdown, no code fences), with this exact shape:
            {"repairs":[{"tool_call_id":"...","arguments":{}}]}

            Rules:
            - Only include entries for tool_call_ids you can repair.
            - "arguments" MUST be a JSON object (not a string).
            - Do NOT include any other keys.
          TEXT
        end

        def repair_user_prompt(candidates)
          payload = { "candidates" => candidates.map { |c| candidate_for_prompt(c) } }
          JSON.generate(payload)
        rescue StandardError
          ""
        end

        def candidate_for_prompt(candidate)
          {
            "tool_call_id" => candidate.fetch(:tool_call_id).to_s,
            "tool_name" => candidate.fetch(:tool_name).to_s,
            "parse_error" => candidate.fetch(:parse_error).to_s,
            "validation_errors_summary" => candidate.fetch(:validation_errors_summary).to_s,
            "arguments_raw_preview" => candidate.fetch(:arguments_raw_preview).to_s,
            "schema" => candidate.fetch(:schema),
          }
        end

        def retry_instructions(attempt_idx)
          <<~TEXT
            Previous output was invalid JSON or did not match the required shape.
            Retry attempt #{attempt_idx + 1}: Output ONLY the JSON object with exactly {"repairs":[{"tool_call_id":"...","arguments":{}}]}.
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

        def apply_repairs(tool_calls, payload, candidates:)
          candidate_ids = {}
          Array(candidates).each do |c|
            id = c.fetch(:tool_call_id, nil).to_s
            next if id.strip.empty?

            candidate_ids[id] = true
          rescue StandardError
            next
          end

          return [tool_calls, 0, candidate_ids.length, []] unless payload.is_a?(Hash)

          repairs = payload.fetch("repairs", nil)
          return [tool_calls, 0, candidate_ids.length, [{ "tool_call_id" => "", "reason" => "invalid_shape" }]] unless repairs.is_a?(Array)

          by_id = {}
          repairs.each do |entry|
            next unless entry.is_a?(Hash)

            id = entry.fetch("tool_call_id", "").to_s
            next if id.strip.empty?

            by_id[id] = entry
          end

          failures = []
          repaired = 0

          repaired_tool_calls =
            tool_calls.map do |tc|
              id = safe_tool_call_id(tc)
              next tc unless candidate_ids[id]

              entry = by_id[id]
              unless entry
                failures << { "tool_call_id" => id, "reason" => "missing_repair" }
                next tc
              end

              args = entry.fetch("arguments", nil)
              unless args.is_a?(Hash)
                failures << { "tool_call_id" => id, "reason" => "arguments_not_object" }
                next tc
              end

              begin
                json = JSON.generate(args)
                if json.bytesize > AgentCore::Utils::DEFAULT_MAX_TOOL_ARGS_BYTES
                  failures << { "tool_call_id" => id, "reason" => "arguments_too_large" }
                  next tc
                end
              rescue StandardError
                failures << { "tool_call_id" => id, "reason" => "arguments_invalid_json" }
                next tc
              end

              repaired += 1
              AgentCore::ToolCall.new(
                id: tc.id,
                name: tc.name,
                arguments: args,
                arguments_parse_error: nil,
              )
            end

          [repaired_tool_calls, repaired, candidate_ids.length - repaired, failures.first(10)]
        rescue StandardError
          [tool_calls, 0, Array(candidates).length, [{ "tool_call_id" => "", "reason" => "apply_repairs_error" }]]
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

        def index_visible_tools(tools)
          out = {}

          Array(tools).each do |tool|
            next unless tool.is_a?(Hash)

            h = AgentCore::Utils.symbolize_keys(tool)

            name = h.fetch(:name, nil)
            schema = h.fetch(:parameters, nil)

            if name.nil? || name.to_s.strip.empty?
              type = h.fetch(:type, nil).to_s
              if type == "function" && h.fetch(:function, nil).is_a?(Hash)
                fn = AgentCore::Utils.symbolize_keys(h.fetch(:function))
                name = fn.fetch(:name, nil)
                schema = fn.fetch(:parameters, nil)
              end
            end

            schema ||= h.fetch(:input_schema, nil)

            name = name.to_s.strip
            next if name.empty?

            out[name] ||= { name: name, schema: schema.is_a?(Hash) ? schema : {} }
          rescue StandardError
            next
          end

          out
        end

        def targeted_parse_error_reason(parse_error)
          return nil if parse_error.nil?

          case parse_error.to_s
          when "invalid_json", "too_large" then parse_error.to_s
          else nil
          end
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

          @instrumenter.publish("agent_core.tool.repair", payload) if @instrumenter.respond_to?(:publish)
        rescue StandardError
          nil
        end

        def build_metadata(attempts:, candidates:, candidates_total:, candidates_sent:, repaired:, failed:, skipped:, max_schema_bytes:, schema_truncated_candidates:, failures_sample:, model:)
          model_name = model.to_s.strip
          model_name = nil if model_name.empty?

          sample = Array(failures_sample).first(10)
          sample = sample.map { |h| h.is_a?(Hash) ? AgentCore::Utils.deep_stringify_keys(h) : { "reason" => h.to_s } }

          {
            "tool_loop" => {
              "repair" => {
                "attempts" => attempts,
                "candidates" => candidates,
                "candidates_total" => candidates_total,
                "candidates_sent" => candidates_sent,
                "repaired" => repaired,
                "failed" => failed,
                "skipped" => skipped,
                "failures_sample" => sample,
                "model" => model_name,
                "max_schema_bytes" => max_schema_bytes,
                "schema_truncated_candidates" => schema_truncated_candidates,
              }.compact,
            },
          }
        rescue StandardError
          {}
        end

        def prepare_schema_for_prompt(schema)
          excerpt = schema_excerpt(schema, depth_left: @schema_max_depth)
          bytes = json_bytesize(excerpt)
          return [excerpt, false] if bytes && bytes <= @max_schema_bytes

          degraded = schema_properties_keys_only(schema)
          degraded_bytes = json_bytesize(degraded)
          return [degraded, true] if degraded_bytes && degraded_bytes <= @max_schema_bytes

          [{}, true]
        rescue StandardError
          [{}, true]
        end

        def json_bytesize(value)
          JSON.generate(value).bytesize
        rescue StandardError
          nil
        end

        def schema_excerpt(schema, depth_left:)
          s = schema.is_a?(Hash) ? schema : {}

          out = {}

          type = s.fetch("type", s.fetch(:type, nil))
          out["type"] = type if type

          ap = s.fetch("additionalProperties", s.fetch(:additionalProperties, nil))
          out["additionalProperties"] = ap if ap == true || ap == false

          req = s.fetch("required", s.fetch(:required, nil))
          out["required"] = Array(req).map { |v| v.to_s }.reject(&:empty?) if req.is_a?(Array)

          enum = s.fetch("enum", s.fetch(:enum, nil))
          out["enum"] = enum if enum.is_a?(Array)

          props = s.fetch("properties", s.fetch(:properties, nil))
          if props.is_a?(Hash)
            out["properties"] = {}
            props.each do |k, v|
              key = k.to_s
              next if key.empty?

              out["properties"][key] =
                if depth_left <= 0
                  {}
                else
                  schema_excerpt(v, depth_left: depth_left - 1)
                end
            end
          end

          items = s.fetch("items", s.fetch(:items, nil))
          if items.is_a?(Hash)
            out["items"] =
              if depth_left <= 0
                {}
              else
                schema_excerpt(items, depth_left: depth_left - 1)
              end
          end

          out
        rescue StandardError
          {}
        end

        def schema_properties_keys_only(schema)
          s = schema.is_a?(Hash) ? schema : {}
          return {} unless object_schema?(s)

          out = {}

          type = s.fetch("type", s.fetch(:type, nil))
          out["type"] = type if type

          ap = s.fetch("additionalProperties", s.fetch(:additionalProperties, nil))
          out["additionalProperties"] = ap if ap == true || ap == false

          req = s.fetch("required", s.fetch(:required, nil))
          out["required"] = Array(req).map { |v| v.to_s }.reject(&:empty?) if req.is_a?(Array)

          props = s.fetch("properties", s.fetch(:properties, nil))
          if props.is_a?(Hash)
            out["properties"] = props.keys.each_with_object({}) do |k, h|
              key = k.to_s
              next if key.empty?

              h[key] = {}
            end
          end

          out
        rescue StandardError
          {}
        end

        def object_schema?(schema)
          t = schema.fetch("type", schema.fetch(:type, nil))
          case t
          when Array
            t.map { |v| v.to_s }.include?("object")
          else
            t.to_s == "object"
          end
        rescue StandardError
          false
        end
      end
    end
  end
end
