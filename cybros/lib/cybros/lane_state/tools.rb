require "set"

module Cybros
  module LaneState
    module Tools
      module_function

      def build
        [build_merge_lane_state_tool]
      end

      def build_merge_lane_state_tool
        AgentCore::Resources::Tools::Tool.new(
          name: "merge_lane_state",
          description: "Merge frozen lane-state snapshots into the target lane.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              "target_lane_id" => { type: "string" },
              "source_lane_ids" => { type: "array", items: { type: "string" } },
              "target_lane_kv_snapshot" => { type: "array", items: { type: "object" } },
              "source_lane_kv_snapshots" => { type: "array", items: { type: "object" } },
              "target_prompt_buffer_snapshot" => { type: "array", items: { type: "object" } },
              "source_prompt_buffer_snapshots" => { type: "array", items: { type: "object" } },
              "merge_metadata" => { type: "object" },
              "archive_source_lanes" => { type: "boolean" },
            },
            required: [
              "target_lane_id",
              "source_lane_ids",
              "target_lane_kv_snapshot",
              "source_lane_kv_snapshots",
              "target_prompt_buffer_snapshot",
              "source_prompt_buffer_snapshots",
              "merge_metadata",
              "archive_source_lanes",
            ],
          },
          metadata: { source: :cybros, category: :lane_state, permission_class: "write" },
        ) do |args, context:|
          task_node = current_task_node!(context)
          target_lane = target_lane_for!(task_node: task_node, lane_id: args.fetch("target_lane_id"))
          source_lanes = source_lanes_for!(task_node: task_node, lane_ids: args.fetch("source_lane_ids"))
          merge_result = build_merge_result(args)

          ::LaneState::MergeResultApplier.apply!(
            task_node: task_node,
            target_lane: target_lane,
            result: merge_result,
            source_lanes: source_lanes,
          )

          AgentCore::Resources::Tools::ToolResult.success(
            text: merge_result.fetch("summary"),
            metadata: merge_result,
          )
        end
      end

      def current_task_node!(context)
        node_id = context&.attributes&.dig(:dag, :node_id).to_s
        node = DAG::Node.find_by(id: node_id)
        return node if node

        AgentCore::ValidationError.raise!(
          "merge_lane_state requires a current DAG task node",
          code: "cybros.lane_state.merge_lane_state.current_task_node_required",
        )
      end
      private_class_method :current_task_node!

      def target_lane_for!(task_node:, lane_id:)
        lane = task_node.graph.lanes.find_by(id: lane_id.to_s)
        return lane if lane

        AgentCore::ValidationError.raise!(
          "merge_lane_state target_lane_id is invalid",
          code: "cybros.lane_state.merge_lane_state.target_lane_not_found",
          details: { target_lane_id: lane_id.to_s },
        )
      end
      private_class_method :target_lane_for!

      def source_lanes_for!(task_node:, lane_ids:)
        ids = Array(lane_ids).map(&:to_s)
        lanes = task_node.graph.lanes.where(id: ids).to_a
        return lanes if lanes.length == ids.uniq.length

        AgentCore::ValidationError.raise!(
          "merge_lane_state source_lane_ids are invalid",
          code: "cybros.lane_state.merge_lane_state.source_lanes_not_found",
          details: { source_lane_ids: ids },
        )
      end
      private_class_method :source_lanes_for!

      def build_merge_result(args)
        target_kv_snapshot = Array(args.fetch("target_lane_kv_snapshot")).map { |entry| normalize_json(entry) }
        source_kv_snapshots = Array(args.fetch("source_lane_kv_snapshots")).map { |entry| normalize_json(entry) }
        target_prompt_buffer_snapshot = Array(args.fetch("target_prompt_buffer_snapshot")).map { |entry| normalize_json(entry) }
        source_prompt_buffer_snapshots = Array(args.fetch("source_prompt_buffer_snapshots")).map { |entry| normalize_json(entry) }

        kv_patch, conflicts = build_lane_kv_patch(target_snapshot: target_kv_snapshot, source_snapshots: source_kv_snapshots)
        prompt_buffer_patch =
          build_prompt_buffer_patch(
            target_snapshot: target_prompt_buffer_snapshot,
            source_snapshots: source_prompt_buffer_snapshots,
          )

        {
          "target_lane_kv_patch" => kv_patch,
          "target_prompt_buffer_patch" => prompt_buffer_patch,
          "conflicts" => conflicts,
          "summary" => build_summary(source_lane_ids: Array(args.fetch("source_lane_ids")), kv_patch: kv_patch, prompt_buffer_patch: prompt_buffer_patch, conflicts: conflicts),
          "archive_source_lanes" => args.fetch("archive_source_lanes") == true,
          "source_lane_ids" => Array(args.fetch("source_lane_ids")).map(&:to_s),
        }
      end
      private_class_method :build_merge_result

      def build_lane_kv_patch(target_snapshot:, source_snapshots:)
        merged_values =
          Array(target_snapshot).each_with_object({}) do |entry, out|
            next unless entry.is_a?(Hash)

            out[entry.fetch("key").to_s] = normalize_json(entry.fetch("value", nil))
          end

        kv_patch = []
        conflicts = []

        Array(source_snapshots).each do |snapshot|
          lane_id = snapshot.fetch("lane_id", "").to_s

          Array(snapshot.fetch("entries", [])).each do |entry|
            next unless entry.is_a?(Hash)

            key = entry.fetch("key").to_s
            value = normalize_json(entry.fetch("value", nil))
            existing_value = merged_values[key]

            if merged_values.key?(key) && existing_value != value
              conflicts << {
                "type" => "lane_kv",
                "key" => key,
                "target_value" => existing_value,
                "source_value" => value,
                "source_lane_id" => lane_id,
              }
            end

            merged_values[key] = value
            kv_patch.reject! { |operation| operation["op"] == "set" && operation["key"] == key }
            kv_patch << { "op" => "set", "key" => key, "value" => value }
          end
        end

        [kv_patch, conflicts]
      end
      private_class_method :build_lane_kv_patch

      def build_prompt_buffer_patch(target_snapshot:, source_snapshots:)
        seen = Set.new

        Array(target_snapshot).each do |entry|
          seen << prompt_buffer_signature(entry)
        end

        patch = []

        Array(source_snapshots).each do |snapshot|
          lane_id = snapshot.fetch("lane_id", "").to_s

          Array(snapshot.fetch("entries", [])).each do |entry|
            normalized_entry = normalize_prompt_buffer_entry(entry, source_lane_id: lane_id)
            signature = prompt_buffer_signature(normalized_entry)
            next if seen.include?(signature)

            seen << signature
            patch << { "op" => "put", "entry" => normalized_entry }
          end
        end

        patch
      end
      private_class_method :build_prompt_buffer_patch

      def normalize_prompt_buffer_entry(entry, source_lane_id:)
        normalized = normalize_json(entry)
        metadata = normalized.fetch("metadata", {})
        metadata = metadata.is_a?(Hash) ? metadata : {}
        metadata["merged_from_lane_id"] = source_lane_id if source_lane_id.present?

        {
          "buffer_name" => normalized.fetch("buffer_name").to_s,
          "kind" => normalized.fetch("kind", "note").to_s,
          "content" => normalized.fetch("content").to_s,
          "priority" => Integer(normalized.fetch("priority", 0), exception: false) || 0,
          "estimated_tokens" => Integer(normalized.fetch("estimated_tokens", 0), exception: false) || 0,
          "metadata" => metadata,
        }
      end
      private_class_method :normalize_prompt_buffer_entry

      def prompt_buffer_signature(entry)
        normalized = normalize_json(entry)
        [
          normalized.fetch("buffer_name", "").to_s,
          normalized.fetch("kind", "").to_s,
          normalized.fetch("content", "").to_s,
        ]
      end
      private_class_method :prompt_buffer_signature

      def build_summary(source_lane_ids:, kv_patch:, prompt_buffer_patch:, conflicts:)
        "Merged lane state from #{Array(source_lane_ids).length} source lane(s); " \
          "#{Array(kv_patch).length} kv update(s); " \
          "#{Array(prompt_buffer_patch).length} prompt buffer entry update(s); " \
          "#{Array(conflicts).length} conflict(s)."
      end
      private_class_method :build_summary

      def normalize_json(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), out|
            out[key.to_s] = normalize_json(nested_value)
          end
        when Array
          value.map { |element| normalize_json(element) }
        else
          value
        end
      end
      private_class_method :normalize_json
    end
  end
end
