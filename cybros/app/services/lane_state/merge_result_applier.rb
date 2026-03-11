class LaneState::MergeResultApplier
  def self.apply!(task_node:, target_lane:, result:, source_lanes: [])
    new(task_node: task_node, target_lane: target_lane, result: result, source_lanes: source_lanes).apply!
  end

  def initialize(task_node:, target_lane:, result:, source_lanes: [])
    @task_node = task_node
    @target_lane = target_lane
    @result = result.is_a?(Hash) ? result.deep_stringify_keys : {}
    @source_lanes = Array(source_lanes)
  end

  def apply!
    target_lane.with_lock do
      apply_lane_kv_patch!
      apply_prompt_buffer_patch!
    end

    archive_source_lanes! if result["archive_source_lanes"] == true
    true
  end

  private

    attr_reader :task_node, :target_lane, :result, :source_lanes

    def apply_lane_kv_patch!
      Array(result["target_lane_kv_patch"]).each do |operation|
        next unless operation.is_a?(Hash)

        case operation["op"].to_s
        when "set"
          key = operation.fetch("key").to_s
          entry = target_lane.lane_kv_entries.find_or_initialize_by(key: key)
          entry.value = normalize_json(operation.fetch("value"))
          entry.written_by_type = "DAG::Node"
          entry.written_by_id = task_node.id
          entry.save!
        when "delete"
          target_lane.lane_kv_entries.where(key: operation.fetch("key").to_s).delete_all
        when "clear"
          target_lane.lane_kv_entries.delete_all
        end
      end
    end

    def apply_prompt_buffer_patch!
      Array(result["target_prompt_buffer_patch"]).each do |operation|
        next unless operation.is_a?(Hash)

        case operation["op"].to_s
        when "put"
          apply_prompt_buffer_put!(operation.fetch("entry"))
        when "delete"
          target_lane.lane_prompt_buffer_entries.where(id: operation.fetch("entry_id").to_s).delete_all
        when "clear"
          target_lane.lane_prompt_buffer_entries.where(buffer_name: operation.fetch("buffer_name").to_s).delete_all
        end
      end
    end

    def apply_prompt_buffer_put!(entry_payload)
      payload = entry_payload.is_a?(Hash) ? entry_payload.deep_stringify_keys : {}
      buffer_name = payload.fetch("buffer_name").to_s
      next_seq = target_lane.lane_prompt_buffer_entries.where(buffer_name: buffer_name).maximum(:seq).to_i + AgentRPC::KernelServices::LanePromptBuffer::SEQ_STEP
      next_seq = AgentRPC::KernelServices::LanePromptBuffer::SEQ_STEP if next_seq <= 0

      target_lane.lane_prompt_buffer_entries.create!(
        buffer_name: buffer_name,
        seq: next_seq,
        kind: payload.fetch("kind", "note").to_s,
        content: payload.fetch("content").to_s,
        priority: Integer(payload.fetch("priority", 0), exception: false) || 0,
        estimated_tokens: Integer(payload.fetch("estimated_tokens", 0), exception: false) || 0,
        metadata: normalize_json(payload.fetch("metadata", {})),
      )
    end

    def archive_source_lanes!
      source_lanes.each do |lane|
        next if lane.archived_at.present?

        task_node.graph.mutate! do |mutations|
          mutations.archive_lane!(lane: lane, mode: :finish, reason: "merge_lane_state")
        end
      end
    end

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
end
